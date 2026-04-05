#models/session.py
from sqlalchemy import Column, Integer, String, ForeignKey, DateTime
from sqlalchemy.orm import relationship
from datetime import datetime, timezone

from db import Base


def _now():
    return datetime.now(timezone.utc)


class Session(Base):
    __tablename__ = "sessions"

    id = Column(Integer, primary_key=True)

    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))
    user = relationship("User")

    device_id = Column(String, index=True)
    refresh_token = Column(String, unique=True, index=True)

    user_agent = Column(String, nullable=True)

    created_at = Column(DateTime(timezone=True), default=_now)
    last_active = Column(DateTime(timezone=True), default=_now)