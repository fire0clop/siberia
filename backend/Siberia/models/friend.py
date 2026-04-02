# models/friend.py

from sqlalchemy import Column, Integer, ForeignKey, Enum, UniqueConstraint
from sqlalchemy.orm import relationship
import enum

from db import Base


class FriendStatus(str, enum.Enum):
    pending = "pending"
    accepted = "accepted"
    rejected = "rejected"


class Friend(Base):
    __tablename__ = "friends"

    id = Column(Integer, primary_key=True)

    requester_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))
    addressee_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))

    status = Column(Enum(FriendStatus), default=FriendStatus.pending)

    requester = relationship("User", foreign_keys=[requester_id])
    addressee = relationship("User", foreign_keys=[addressee_id])

    __table_args__ = (
        UniqueConstraint("requester_id", "addressee_id", name="uq_friend_request"),
    )