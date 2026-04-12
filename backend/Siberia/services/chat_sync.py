from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from models.chat import Chat
from models.chat_update import ChatUpdate

from services.chat import check_user_in_chat


async def get_updates_since(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
    after_seq: int,
    limit: int,
):
    await check_user_in_chat(db, user_id, chat_id)

    chat = await db.get(Chat, chat_id)
    if not chat:
        return [], 0

    stmt = (
        select(ChatUpdate)
        .where(
            ChatUpdate.chat_id == chat_id,
            ChatUpdate.seq > after_seq,
        )
        .order_by(ChatUpdate.seq)
        .limit(limit)
    )
    result = await db.execute(stmt)
    updates = result.scalars().all()

    items = [
        {
            "seq": u.seq,
            "event": u.event_type.value,
            "message_id": u.message_id,
            "payload": u.payload if u.payload is not None else {},
            "created_at": u.created_at.isoformat() if u.created_at else None,
        }
        for u in updates
    ]
    return items, int(chat.sync_seq or 0)
