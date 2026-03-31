# models/call.py
import enum
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, ForeignKey, Enum, DateTime, Index
from sqlalchemy.orm import relationship

from db import Base


class CallType(str, enum.Enum):
    audio = "audio"
    video = "video"


class CallStatus(str, enum.Enum):
    ringing   = "ringing"     # созданный, ждём ответа
    active    = "active"      # принят, медиа течёт
    ended     = "ended"       # нормально завершён обеими сторонами
    declined  = "declined"    # callee нажал «отклонить»
    missed    = "missed"      # callee не ответил за таймаут
    cancelled = "cancelled"   # caller отменил до ответа


def _now():
    return datetime.now(timezone.utc)


class Call(Base):
    __tablename__ = "calls"

    id = Column(Integer, primary_key=True)

    caller_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    callee_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)

    # Опционально привязываем к 1-on-1 чату — чтобы показывать «звонок» в ленте чата.
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="SET NULL"), nullable=True, index=True)

    type   = Column(Enum(CallType),   nullable=False, default=CallType.audio,    server_default="audio")
    status = Column(Enum(CallStatus), nullable=False, default=CallStatus.ringing, server_default="ringing")

    started_at  = Column(DateTime(timezone=True), default=_now,   nullable=False)
    accepted_at = Column(DateTime(timezone=True), nullable=True)
    ended_at    = Column(DateTime(timezone=True), nullable=True)

    # Длительность активной части в секундах (когда status=ended)
    duration_seconds = Column(Integer, nullable=True)

    caller = relationship("User", foreign_keys=[caller_id])
    callee = relationship("User", foreign_keys=[callee_id])

    __table_args__ = (
        Index("ix_calls_caller_started", "caller_id", "started_at"),
        Index("ix_calls_callee_started", "callee_id", "started_at"),
    )
