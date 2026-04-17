from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import func

from fastapi import HTTPException

from models.message import Message
from models.message_reaction import MessageReaction
from models.chat_update import ChatUpdateEventType
from services.chat import check_user_in_chat
from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope


async def _reactions_for_message(db: AsyncSession, message_id: int) -> dict[str, int]:
    stmt = (
        select(MessageReaction.emoji, func.count(MessageReaction.id))
        .where(MessageReaction.message_id == message_id)
        .group_by(MessageReaction.emoji)
    )
    result = await db.execute(stmt)
    return {emoji: count for emoji, count in result.all()}


async def add_reaction(db: AsyncSession, user_id: int, message_id: int, emoji: str) -> dict:
    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.deleted_at is not None:
        raise HTTPException(status_code=400, detail="Cannot react to deleted message")

    await check_user_in_chat(db, user_id, message.chat_id)

    existing = await db.execute(
        select(MessageReaction).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user_id,
        )
    )
    reaction = existing.scalars().first()

    if reaction:
        if reaction.emoji == emoji:
            reactions = await _reactions_for_message(db, message_id)
            return reactions
        reaction.emoji = emoji
    else:
        db.add(MessageReaction(message_id=message_id, user_id=user_id, emoji=emoji))

    await db.flush()

    reactions = await _reactions_for_message(db, message_id)

    chat = await lock_chat_row(db, message.chat_id)
    seq, _ = await log_update_on_locked_chat(
        db, chat, ChatUpdateEventType.reaction_update, message_id,
        {"message_id": message_id, "reactions": reactions},
    )
    await db.commit()

    env = build_envelope(
        message.chat_id, seq, ChatUpdateEventType.reaction_update, message_id,
        {"message_id": message_id, "reactions": reactions},
    )
    await broadcast_envelope(message.chat_id, env)

    return reactions


async def remove_reaction(db: AsyncSession, user_id: int, message_id: int) -> dict:
    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")

    await check_user_in_chat(db, user_id, message.chat_id)

    existing = await db.execute(
        select(MessageReaction).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user_id,
        )
    )
    reaction = existing.scalars().first()
    if reaction:
        await db.delete(reaction)
        await db.flush()

    reactions = await _reactions_for_message(db, message_id)

    chat = await lock_chat_row(db, message.chat_id)
    seq, _ = await log_update_on_locked_chat(
        db, chat, ChatUpdateEventType.reaction_update, message_id,
        {"message_id": message_id, "reactions": reactions},
    )
    await db.commit()

    env = build_envelope(
        message.chat_id, seq, ChatUpdateEventType.reaction_update, message_id,
        {"message_id": message_id, "reactions": reactions},
    )
    await broadcast_envelope(message.chat_id, env)

    return reactions
