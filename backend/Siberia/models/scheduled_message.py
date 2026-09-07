# models/scheduled_message.py
import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, BigInteger, Text, ForeignKey, DateTime
from sqlalchemy.dialects.postgresql import JSONB, UUID

from db import Base


def _now():
    return datetime.now(timezone.utc)


class ScheduledMessage(Base):
    """Отложенное сообщение ДО отправки.

    Настоящая строка в messages создаётся воркером в момент доставки —
    со свежим id (корректная позиция в ленте) и статусами. Идемпотентность
    доставки обеспечивает client_message_id.
    """
    __tablename__ = "scheduled_messages"

    id = Column(Integer, primary_key=True)
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    text = Column(Text, nullable=True)
    text_entities = Column(JSONB, nullable=True)
    media_id = Column(UUID(as_uuid=True), ForeignKey("media.id", ondelete="SET NULL"), nullable=True)
    reply_to_message_id = Column(BigInteger, nullable=True)
    client_message_id = Column(UUID(as_uuid=True), nullable=False, unique=True, default=uuid.uuid4)
    send_at = Column(DateTime(timezone=True), nullable=False, index=True)
    created_at = Column(DateTime(timezone=True), default=_now, nullable=False)
