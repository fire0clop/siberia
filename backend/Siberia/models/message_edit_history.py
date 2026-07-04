from datetime import datetime, timezone

from sqlalchemy import Column, BigInteger, Text, DateTime, ForeignKey, Index

from db import Base


class MessageEditHistory(Base):
    """Снимок предыдущего текста сообщения при каждом редактировании.

    При первом редактировании сохраняем оригинальный текст; при последующих —
    предыдущую версию. Так можно показать пользователю всю историю изменений.
    """
    __tablename__ = "message_edit_history"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    message_id = Column(
        BigInteger,
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    text = Column(Text, nullable=True)
    edited_at = Column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        nullable=False,
    )

    __table_args__ = (
        Index("ix_message_edit_history_msg_at", "message_id", "edited_at"),
    )
