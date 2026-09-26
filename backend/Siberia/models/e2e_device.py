# models/e2e_device.py — публичный X25519 identity-ключ ОТДЕЛЬНОГО устройства.
#
# Мультидевайс (стадия 3): у пользователя несколько устройств, у каждого свой
# ключ. Сообщение шифруется на все устройства собеседника (и на свои другие).
# device_id — стабильный идентификатор инсталляции клиента (тот же, что в
# sessions.device_id / заголовке X-Device-ID).
from datetime import datetime, timezone

from sqlalchemy import (
    Column, Integer, String, ForeignKey, DateTime, UniqueConstraint, Index,
)

from db import Base


def _now():
    return datetime.now(timezone.utc)


class E2EDevice(Base):
    __tablename__ = "e2e_devices"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    device_id = Column(String(128), nullable=False)
    public_key = Column(String(128), nullable=False)  # X25519 pub, base64 (32 байта)
    created_at = Column(DateTime(timezone=True), default=_now, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=_now, nullable=False)

    __table_args__ = (
        # одно устройство — одна запись; повторный PUT обновляет ключ
        UniqueConstraint("user_id", "device_id", name="uq_e2e_device_user_device"),
        Index("ix_e2e_devices_user_id", "user_id"),
    )
