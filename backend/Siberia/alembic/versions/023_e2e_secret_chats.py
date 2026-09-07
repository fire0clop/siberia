"""E2E секретные чаты (v1: X25519 + HKDF + AES-GCM, шифрование на клиенте)

Сервер — только транспорт: хранит публичные identity-ключи устройств,
handshake-материал чата (эфемерный публичный ключ создателя + снапшоты
identity-ключей) и непрозрачные encrypted_payload сообщений. Приватные
ключи и plaintext сервера никогда не достигают.

Ограничения v1 (сознательные): нет per-message ratchet (компрометация
ключа чата раскрывает его историю), одно устройство на пользователя
(новый ключ устройства = старые секретные чаты нечитаемы).

Revision ID: 023_e2e_secret_chats
Revises: 022_stories
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB


revision: str = "023_e2e_secret_chats"
down_revision: Union[str, None] = "022_stories"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TYPE chattype ADD VALUE IF NOT EXISTS 'secret'")

    op.create_table(
        "e2e_keys",
        sa.Column("user_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("public_key", sa.String(128), nullable=False),  # base64 X25519 (32B)
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()"), nullable=False),
    )

    # Handshake-материал секретного чата:
    # {creator_id, eph_pub, creator_identity_pub, peer_identity_pub}
    op.add_column("chats", sa.Column("e2e_handshake", JSONB, nullable=True))

    # Непрозрачный шифроблоб сообщения: base64(nonce || AES-GCM ciphertext+tag)
    op.add_column("messages", sa.Column("encrypted_payload", sa.Text, nullable=True))


def downgrade() -> None:
    op.drop_column("messages", "encrypted_payload")
    op.drop_column("chats", "e2e_handshake")
    op.drop_table("e2e_keys")
    # значение enum не убираем (PG не поддерживает DROP VALUE)
