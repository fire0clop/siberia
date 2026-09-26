# models/e2e_key_backup.py — зашифрованный бэкап identity-ключа пользователя.
#
# Стадия 4b: чтобы переустановка/новое устройство могли восстановить свою
# криптоличность, клиент кладёт identity-ключ, завёрнутый под ключом из
# ПАССФРАЗЫ (PBKDF2 → AES-GCM). Сервер хранит только непрозрачный ciphertext,
# соль и число итераций — пассфразы и ключа он не знает.
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, String, Text, ForeignKey, DateTime

from db import Base


class E2EKeyBackup(Base):
    __tablename__ = "e2e_key_backups"

    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    ciphertext = Column(Text, nullable=False)   # base64(nonce||AES-GCM(identity_priv))
    salt = Column(String(128), nullable=False)  # base64 соли PBKDF2
    iterations = Column(Integer, nullable=False)
    updated_at = Column(DateTime(timezone=True),
                        default=lambda: datetime.now(timezone.utc), nullable=False)
