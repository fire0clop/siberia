from datetime import datetime, timezone

from sqlalchemy import Column, Integer, BigInteger, ForeignKey, String, DateTime, UniqueConstraint
from sqlalchemy.orm import relationship

from db import Base


class MessageReaction(Base):
    __tablename__ = "message_reactions"

    id = Column(Integer, primary_key=True)
    message_id = Column(
        BigInteger, ForeignKey("messages.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    emoji = Column(String(8), nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    user = relationship("User")

    __table_args__ = (
        UniqueConstraint("message_id", "user_id", name="uq_reaction_user_message"),
    )
