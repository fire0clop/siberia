"""Мультидевайс (стадия 3a): реестр публичных ключей устройств

Таблица e2e_devices — по строке на устройство пользователя (user_id, device_id)
с его X25519 identity-pub. e2e_keys (один ключ на юзера) пока сохраняем для
обратной совместимости с DM-handshake стадии 2; клиенты дозаполняют реестр
устройств при следующем запуске.

Revision ID: 027_e2e_devices
Revises: 026_wipe_plaintext_dm_history
Create Date: 2026-09-26
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "027_e2e_devices"
down_revision: Union[str, None] = "026_wipe_plaintext_dm_history"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "e2e_devices",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=False),
        sa.Column("public_key", sa.String(length=128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("user_id", "device_id", name="uq_e2e_device_user_device"),
    )
    op.create_index("ix_e2e_devices_user_id", "e2e_devices", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_e2e_devices_user_id", table_name="e2e_devices")
    op.drop_table("e2e_devices")
