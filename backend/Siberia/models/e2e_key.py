# models/e2e_key.py
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, String, ForeignKey, DateTime

from db import Base


class E2EKey(Base):
    """Публичный X25519 identity-ключ устройства пользователя (v1: один на юзера)."""
    __tablename__ = "e2e_keys"

    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    public_key = Column(String(128), nullable=False)
    updated_at = Column(DateTime(timezone=True),
                        default=lambda: datetime.now(timezone.utc), nullable=False)
