import enum

from sqlalchemy import (
    Column,
    Integer,
    BigInteger,
    String,
    ForeignKey,
    DateTime,
    Index,
    Enum,
    text as sa_text,
)
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from datetime import datetime, timezone

from db import Base


class MessageType(str, enum.Enum):
    text = "text"
    system = "system"


class Message(Base):
    __tablename__ = "messages"

    id = Column(BigInteger, primary_key=True, autoincrement=True)

    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True, index=True)

    type = Column(Enum(MessageType), nullable=False, default=MessageType.text, server_default="text")

    text = Column(String, nullable=True)
    media_id = Column(UUID(as_uuid=True), ForeignKey("media.id", ondelete="SET NULL"), nullable=True, index=True)

    client_message_id = Column(UUID(as_uuid=True), nullable=True, index=True)

    reply_to_message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="SET NULL"),
        nullable=True,
    )

    forwarded_from_message_id = Column(BigInteger, nullable=True)
    forwarded_from_user_id = Column(Integer, nullable=True)
    forwarded_from_chat_id = Column(Integer, nullable=True)

    mention_user_ids = Column(JSONB, nullable=True)

    # Разметка текста: [{"type": "bold"|"italic"|..., "offset": N, "length": M}]
    # offset/length — в UTF-16 code units (общий знаменатель Swift/Python)
    text_entities = Column(JSONB, nullable=True)

    # OG-превью первой ссылки: {url,title,description,image_url,site_name}|null.
    # Заполняется асинхронно ARQ-задачей fetch_link_preview.
    link_preview = Column(JSONB, nullable=True)

    @property
    def entities(self):
        """Alias для pydantic from_attributes (API-поле называется entities)."""
        return self.text_entities

    send_at = Column(DateTime(timezone=True), nullable=True)

    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    edited_at = Column(DateTime(timezone=True), nullable=True)
    deleted_at = Column(DateTime(timezone=True), nullable=True)

    chat = relationship(
        "Chat",
        back_populates="messages",
        foreign_keys=[chat_id],
    )

    user = relationship("User")
    media = relationship("Media", foreign_keys=[media_id])

    reply_to = relationship(
        "Message",
        remote_side=[id],
        foreign_keys=[reply_to_message_id],
    )

    statuses = relationship(
        "MessageStatus",
        back_populates="message",
        cascade="all, delete",
    )

    __table_args__ = (
        Index(
            "uq_message_client_idempotency",
            "chat_id",
            "user_id",
            "client_message_id",
            unique=True,
            postgresql_where=sa_text("client_message_id IS NOT NULL"),
        ),
    )
