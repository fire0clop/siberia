import enum
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, BigInteger, Enum, Boolean
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from db import Base


class ChatType(str, enum.Enum):
    private = "private"
    group = "group"
    saved = "saved"
    channel = "channel"


class Chat(Base):
    __tablename__ = "chats"

    id = Column(Integer, primary_key=True)
    type = Column(Enum(ChatType), nullable=False, default=ChatType.private, server_default="private")
    title = Column(String, nullable=True)
    description = Column(String(255), nullable=True)
    avatar_media_id = Column(UUID(as_uuid=True), ForeignKey("media.id", ondelete="SET NULL"), nullable=True)
    max_members = Column(Integer, nullable=False, default=200, server_default="200")
    invite_link = Column(String(32), unique=True, nullable=True, index=True)

    last_message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="SET NULL"),
        nullable=True,
    )

    pinned_message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="SET NULL"),
        nullable=True,
    )

    is_public = Column(Boolean, nullable=False, default=False, server_default="false")
    subscribers_count = Column(Integer, nullable=False, default=0, server_default="0")

    sync_seq = Column(BigInteger, nullable=False, default=0, server_default="0")

    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    messages = relationship(
        "Message",
        back_populates="chat",
        foreign_keys="Message.chat_id",
        cascade="all, delete",
    )

    members = relationship(
        "ChatMember",
        back_populates="chat",
        cascade="all, delete",
    )

    updates = relationship(
        "ChatUpdate",
        back_populates="chat",
        cascade="all, delete",
        order_by="ChatUpdate.seq",
    )
