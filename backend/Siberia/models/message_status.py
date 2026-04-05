from sqlalchemy import Column, Integer, BigInteger, ForeignKey, Enum, UniqueConstraint
from sqlalchemy.orm import relationship
import enum

from db import Base


class MessageStatusEnum(str, enum.Enum):
    sent = "sent"
    delivered = "delivered"
    read = "read"


class MessageStatus(Base):
    __tablename__ = "message_statuses"

    id = Column(Integer, primary_key=True)

    message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="CASCADE"),
        index=True,
    )
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), index=True)

    status = Column(Enum(MessageStatusEnum), nullable=False)

    message = relationship(
        "Message",
        back_populates="statuses",
    )

    __table_args__ = (
        UniqueConstraint("message_id", "user_id", name="uq_message_user"),
    )
