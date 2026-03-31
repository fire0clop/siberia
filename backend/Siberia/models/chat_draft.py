from datetime import datetime, timezone

from sqlalchemy import Column, Integer, BigInteger, ForeignKey, String, DateTime, UniqueConstraint
from sqlalchemy.orm import relationship

from db import Base


class ChatDraft(Base):
    __tablename__ = "chat_drafts"

    id = Column(Integer, primary_key=True)
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    text = Column(String(4096), nullable=False)
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        UniqueConstraint("chat_id", "user_id", name="uq_draft_chat_user"),
    )
