from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from models.chat_member import ChatMember


async def get_chat_member_user_ids(db: AsyncSession, chat_id: int) -> list[int]:
    result = await db.execute(
        select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
    )
    return [row[0] for row in result.all()]
