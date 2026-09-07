# models/chat_folder.py
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, UniqueConstraint

from db import Base


def _now():
    return datetime.now(timezone.utc)


class ChatFolder(Base):
    """Пользовательская папка чатов («Работа», «Семья»…)."""
    __tablename__ = "chat_folders"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(50), nullable=False)
    position = Column(Integer, nullable=False, default=0, server_default="0")
    created_at = Column(DateTime(timezone=True), default=_now, nullable=False)


class ChatFolderItem(Base):
    """M2M: чат внутри папки."""
    __tablename__ = "chat_folder_items"

    id = Column(Integer, primary_key=True)
    folder_id = Column(Integer, ForeignKey("chat_folders.id", ondelete="CASCADE"), nullable=False, index=True)
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), nullable=False)

    __table_args__ = (
        UniqueConstraint("folder_id", "chat_id", name="uq_folder_chat"),
    )
