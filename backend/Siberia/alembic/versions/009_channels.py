"""channels: channel chat type, subscriber role, is_public, subscribers_count

Revision ID: 009_channels
Revises: 008_security
Create Date: 2026-04-19
"""
from typing import Sequence, Union
import sqlalchemy as sa
from alembic import op

revision: str = "009_channels"
down_revision: Union[str, None] = "008_security"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _col(table, col):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.columns WHERE table_name = :t AND column_name = :c AND table_schema = 'public'"),
        {"t": table, "c": col},
    )
    return r.fetchone() is not None


def upgrade() -> None:
    op.execute("ALTER TYPE chattype ADD VALUE IF NOT EXISTS 'channel'")
    op.execute("ALTER TYPE memberrole ADD VALUE IF NOT EXISTS 'subscriber'")

    if not _col("chats", "is_public"):
        op.add_column("chats", sa.Column("is_public", sa.Boolean(), nullable=False, server_default="false"))
    if not _col("chats", "subscribers_count"):
        op.add_column("chats", sa.Column("subscribers_count", sa.Integer(), nullable=False, server_default="0"))


def downgrade() -> None:
    op.drop_column("chats", "subscribers_count")
    op.drop_column("chats", "is_public")
