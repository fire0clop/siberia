"""Групповое E2E (стадия 3b-1): is_e2e, sender_device_id, sender-key раздача

- chats.is_e2e — единый признак шифрования; бэкфилл для уже шифрованных
  (secret + DM с handshake). Группы пока НЕ трогаем (останутся plaintext до
  готовности клиента — их флип отдельной миграцией 3b-3).
- messages.sender_device_id — устройство-отправитель для выбора sender-key.
- e2e_sender_keys — SKDM (раздачи sender-key устройствам-получателям).

Revision ID: 028_group_e2e_sender_keys
Revises: 027_e2e_devices
Create Date: 2026-09-26
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "028_group_e2e_sender_keys"
down_revision: Union[str, None] = "027_e2e_devices"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("chats", sa.Column(
        "is_e2e", sa.Boolean(), nullable=False, server_default="false"
    ))
    # Бэкфилл: уже шифрованные чаты. Все они (и secret, и приватные DM) несут
    # handshake, поэтому одного условия достаточно — и это не трогает enum-литерал
    # 'secret' (Postgres запрещает его использование в той же транзакции, где
    # значение enum было добавлено миграцией 023).
    op.execute("UPDATE chats SET is_e2e = true WHERE e2e_handshake IS NOT NULL")

    op.add_column("messages", sa.Column(
        "sender_device_id", sa.String(length=128), nullable=True
    ))

    op.create_table(
        "e2e_sender_keys",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("chat_id", sa.Integer(), nullable=False),
        sa.Column("from_user_id", sa.Integer(), nullable=False),
        sa.Column("from_device_id", sa.String(length=128), nullable=False),
        sa.Column("to_user_id", sa.Integer(), nullable=False),
        sa.Column("to_device_id", sa.String(length=128), nullable=False),
        sa.Column("key_epoch", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("ciphertext", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["chat_id"], ["chats.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["from_user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["to_user_id"], ["users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint(
            "chat_id", "from_device_id", "to_device_id", "key_epoch",
            name="uq_e2e_sender_key_dist",
        ),
    )
    op.create_index(
        "ix_e2e_sender_keys_recipient", "e2e_sender_keys",
        ["chat_id", "to_user_id", "to_device_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_e2e_sender_keys_recipient", table_name="e2e_sender_keys")
    op.drop_table("e2e_sender_keys")
    op.drop_column("messages", "sender_device_id")
    op.drop_column("chats", "is_e2e")
