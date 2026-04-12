from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import update as sa_update

from models.message import Message
from models.message_status import MessageStatus, MessageStatusEnum
from models.chat_update import ChatUpdateEventType
from services.chat import check_user_in_chat
from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope


async def bulk_mark_read(db: AsyncSession, user_id: int, chat_id: int, up_to_message_id: int) -> None:
    await check_user_in_chat(db, user_id, chat_id)

    # Get all message IDs in this chat up to the given ID
    msg_ids_result = await db.execute(
        select(Message.id).where(
            Message.chat_id == chat_id,
            Message.id <= up_to_message_id,
            Message.deleted_at.is_(None),
        )
    )
    message_ids = [row[0] for row in msg_ids_result.all()]
    if not message_ids:
        return

    # Update existing statuses to read
    await db.execute(
        sa_update(MessageStatus)
        .where(
            MessageStatus.message_id.in_(message_ids),
            MessageStatus.user_id == user_id,
            MessageStatus.status != MessageStatusEnum.read,
        )
        .values(status=MessageStatusEnum.read)
    )

    # Insert missing statuses
    existing_result = await db.execute(
        select(MessageStatus.message_id).where(
            MessageStatus.message_id.in_(message_ids),
            MessageStatus.user_id == user_id,
        )
    )
    existing_ids = {row[0] for row in existing_result.all()}
    missing_ids = set(message_ids) - existing_ids

    for mid in missing_ids:
        db.add(MessageStatus(message_id=mid, user_id=user_id, status=MessageStatusEnum.read))

    chat = await lock_chat_row(db, chat_id)
    seq, _ = await log_update_on_locked_chat(
        db, chat, ChatUpdateEventType.read_receipt, up_to_message_id,
        {"reader_id": user_id, "up_to_message_id": up_to_message_id},
    )
    await db.commit()

    env = build_envelope(
        chat_id, seq, ChatUpdateEventType.read_receipt, up_to_message_id,
        {"reader_id": user_id, "up_to_message_id": up_to_message_id},
    )
    await broadcast_envelope(chat_id, env)
