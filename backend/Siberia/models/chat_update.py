import enum
from sqlalchemy import (
    Column,
    BigInteger,
    Integer,
    ForeignKey,
    DateTime,
    Enum,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import relationship
from datetime import datetime, timezone

from db import Base


class ChatUpdateEventType(str, enum.Enum):
    message_new = "message_new"
    message_edit = "message_edit"
    message_delete = "message_delete"
    read_receipt = "read_receipt"
    member_added = "member_added"
    member_removed = "member_removed"
    member_left = "member_left"
    chat_updated = "chat_updated"
    role_changed = "role_changed"
    reaction_update = "reaction_update"
    message_pinned = "message_pinned"


class ChatUpdate(Base):
    __tablename__ = "chat_updates"

    id = Column(BigInteger, primary_key=True, autoincrement=True)

    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), index=True)
    seq = Column(BigInteger, nullable=False)

    event_type = Column(Enum(ChatUpdateEventType), nullable=False)
    message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="SET NULL"),
        nullable=True,
    )
    payload = Column(JSONB, nullable=True)

    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    chat = relationship("Chat", back_populates="updates")

    __table_args__ = (
        UniqueConstraint("chat_id", "seq", name="uq_chat_update_seq"),
    )
