"""security: email verification, 2fa, login history, account deletion

Revision ID: 008_security
Revises: 007_rich_messages
Create Date: 2026-04-19
"""
from typing import Sequence, Union
import sqlalchemy as sa
from alembic import op

revision: str = "008_security"
down_revision: Union[str, None] = "007_rich_messages"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _tbl(name):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.tables WHERE table_name = :n AND table_schema = 'public'"),
        {"n": name},
    )
    return r.fetchone() is not None


def _col(table, col):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.columns WHERE table_name = :t AND column_name = :c AND table_schema = 'public'"),
        {"t": table, "c": col},
    )
    return r.fetchone() is not None


def upgrade() -> None:
    if not _col("users", "email_verified"):
        op.add_column("users", sa.Column("email_verified", sa.Boolean(), nullable=False, server_default="false"))
    if not _col("users", "totp_secret"):
        op.add_column("users", sa.Column("totp_secret", sa.String(64), nullable=True))
    if not _col("users", "deleted_at"):
        op.add_column("users", sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))

    if not _tbl("email_verifications"):
        op.create_table(
            "email_verifications",
            sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("code", sa.String(6), nullable=False),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("used", sa.Boolean(), nullable=False, server_default="false"),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        )
        op.create_index("ix_email_verifications_user_id", "email_verifications", ["user_id"])

    if not _tbl("login_events"):
        op.create_table(
            "login_events",
            sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=True),
            sa.Column("ip", sa.String(45), nullable=True),
            sa.Column("user_agent", sa.String(512), nullable=True),
            sa.Column("success", sa.Boolean(), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        )
        op.create_index("ix_login_events_user_id", "login_events", ["user_id"])
        op.create_index("ix_login_events_created_at", "login_events", ["created_at"])


def downgrade() -> None:
    op.drop_table("login_events")
    op.drop_table("email_verifications")
    op.drop_column("users", "deleted_at")
    op.drop_column("users", "totp_secret")
    op.drop_column("users", "email_verified")
