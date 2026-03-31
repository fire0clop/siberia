import enum
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, ForeignKey, UniqueConstraint, Enum, DateTime
from sqlalchemy.orm import relationship

from db import Base


class MemberRole(str, enum.Enum):
    owner = "owner"
    admin = "admin"
    member = "member"
    subscriber = "subscriber"


class ChatMember(Base):
    __tablename__ = "chat_members"

    id = Column(Integer, primary_key=True)

    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"))

    role = Column(Enum(MemberRole), nullable=False, default=MemberRole.member, server_default="member")
    joined_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    user = relationship("User", back_populates="chats")
    chat = relationship("Chat", back_populates="members")

    __table_args__ = (
        UniqueConstraint("user_id", "chat_id", name="uq_user_chat"),
    )
