from datetime import datetime, timezone

from sqlalchemy import Column, Integer, ForeignKey, String, DateTime, Boolean
from db import Base


class LoginEvent(Base):
    __tablename__ = "login_events"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True, index=True)
    ip = Column(String(45), nullable=True)
    user_agent = Column(String(512), nullable=True)
    success = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)
