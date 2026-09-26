# models/e2e_sender_key.py — Sender Key Distribution Message (SKDM).
#
# Групповое E2E (стадия 3b, модель Signal sender keys): каждое устройство-
# отправитель имеет симметричный sender-key на чат+эпоху. Чтобы остальные
# устройства могли расшифровать его сообщения, отправитель раздаёт этот ключ
# каждому устройству-получателю, зашифровав попарно (X25519 между устройствами
# → HKDF → AES-GCM). Сервер — транспорт: хранит и отдаёт непрозрачные ciphertext,
# сам ключей не видит.
#
# Ротация: при смене набора устройств-получателей отправитель поднимает эпоху,
# генерирует новый sender-key и раздаёт заново (старые строки остаются — их
# ещё могут дочитать те, кто был в группе на той эпохе).
from datetime import datetime, timezone

from sqlalchemy import (
    Column, Integer, BigInteger, String, Text, ForeignKey, DateTime,
    UniqueConstraint, Index,
)

from db import Base


def _now():
    return datetime.now(timezone.utc)


class E2ESenderKey(Base):
    __tablename__ = "e2e_sender_keys"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    chat_id = Column(Integer, ForeignKey("chats.id", ondelete="CASCADE"), nullable=False)
    from_user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    from_device_id = Column(String(128), nullable=False)
    to_user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    to_device_id = Column(String(128), nullable=False)
    key_epoch = Column(Integer, nullable=False, default=0)
    ciphertext = Column(Text, nullable=False)  # sender-key, завёрнутый для устройства-получателя
    created_at = Column(DateTime(timezone=True), default=_now, nullable=False)

    __table_args__ = (
        # одна раздача на (чат, отправитель-устройство, получатель-устройство, эпоха)
        UniqueConstraint(
            "chat_id", "from_device_id", "to_device_id", "key_epoch",
            name="uq_e2e_sender_key_dist",
        ),
        # быстрый выбор SKDM, адресованных конкретному устройству получателя
        Index("ix_e2e_sender_keys_recipient", "chat_id", "to_user_id", "to_device_id"),
    )
