"""push_tokens and chat_mute_settings tables

Revision ID: 002_push_mute
Revises: 001_baseline
Create Date: 2026-04-19
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "002_push_mute"
down_revision: Union[str, None] = "001_baseline"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _tbl(name):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.tables WHERE table_name = :n AND table_schema = 'public'"),
        {"n": name},
    )
    return r.fetchone() is not None


def upgrade() -> None:
    if not _tbl("push_tokens"):
        op.create_table(
            "push_tokens",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_id", sa.Integer(),
                      sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("session_id", sa.Integer(),
                      sa.ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False),
            sa.Column("device_token", sa.String(512), nullable=False, unique=True),
            sa.Column("platform", sa.Enum("ios", "android", name="pushplatform", create_type=False), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        )
        op.create_index("ix_push_tokens_user_id", "push_tokens", ["user_id"])
        op.create_index("ix_push_tokens_session_id", "push_tokens", ["session_id"])

    if not _tbl("chat_mute_settings"):
        op.create_table(
            "chat_mute_settings",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_id", sa.Integer(),
                      sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("chat_id", sa.Integer(),
                      sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
            sa.Column("muted_until", sa.DateTime(timezone=True), nullable=True),
        )
        op.create_unique_constraint(
            "uq_mute_user_chat", "chat_mute_settings", ["user_id", "chat_id"]
        )


def downgrade() -> None:
    op.drop_table("chat_mute_settings")
    op.drop_index("ix_push_tokens_session_id", table_name="push_tokens")
    op.drop_index("ix_push_tokens_user_id", table_name="push_tokens")
    op.drop_table("push_tokens")
    op.execute("DROP TYPE IF EXISTS pushplatform")
