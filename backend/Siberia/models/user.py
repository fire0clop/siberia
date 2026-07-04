import uuid

from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, Boolean
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from db import Base


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    public_id = Column(String, unique=True, index=True, default=lambda: str(uuid.uuid4()))

    email = Column(String, unique=True, index=True, nullable=False)
    nickname = Column(String, unique=True, index=True, nullable=False)
    # @username — уникальный хэндл (только буквы, цифры, _), отличается от nickname
    username = Column(String(32), unique=True, index=True, nullable=True)
    password = Column(String, nullable=False)

    bio = Column(String(200), nullable=True)
    avatar_media_id = Column(
        UUID(as_uuid=True),
        ForeignKey("media.id", ondelete="SET NULL"),
        nullable=True,
    )
    last_seen_at = Column(DateTime(timezone=True), nullable=True)

    email_verified = Column(Boolean, nullable=False, default=False, server_default="false")
    totp_secret = Column(String(64), nullable=True)
    deleted_at = Column(DateTime(timezone=True), nullable=True)

    chats = relationship("ChatMember", back_populates="user", cascade="all, delete")
    privacy = relationship(
        "PrivacySetting",
        uselist=False,
        cascade="all, delete-orphan",
        foreign_keys="PrivacySetting.user_id",
    )
