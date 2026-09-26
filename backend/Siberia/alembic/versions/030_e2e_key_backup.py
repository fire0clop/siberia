"""Стадия 4b: зашифрованный бэкап identity-ключа под пассфразу

Таблица e2e_key_backups — по одной записи на пользователя: непрозрачный
ciphertext (identity-ключ, завёрнутый ключом из пассфразы), соль и число
итераций PBKDF2. Сервер пассфразы/ключа не видит.

Revision ID: 030_e2e_key_backup
Revises: 029_flip_groups_to_e2e
Create Date: 2026-09-26
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "030_e2e_key_backup"
down_revision: Union[str, None] = "029_flip_groups_to_e2e"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "e2e_key_backups",
        sa.Column("user_id", sa.Integer(), primary_key=True),
        sa.Column("ciphertext", sa.Text(), nullable=False),
        sa.Column("salt", sa.String(length=128), nullable=False),
        sa.Column("iterations", sa.Integer(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )


def downgrade() -> None:
    op.drop_table("e2e_key_backups")
