
from sqlalchemy import Column, Integer, ForeignKey, DateTime, UniqueConstraint
from sqlalchemy.orm import relationship

from db import Base


class ChatMuteSetting(Base):
    __tablename__ = "chat_mute_settings"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), nullable=False)
    # NULL = замьючен навсегда; дата = замьючен до указанного времени
    muted_until = Column(DateTime(timezone=True), nullable=True)

    user = relationship("User")
    chat = relationship("Chat")

    __table_args__ = (
        UniqueConstraint("user_id", "chat_id", name="uq_mute_user_chat"),
    )
