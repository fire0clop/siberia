"""user profile fields and privacy_settings table

Revision ID: 004_profile
Revises: 003_media
Create Date: 2026-04-19
"""
from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from alembic import op

revision: str = "004_profile"
down_revision: Union[str, None] = "003_media"
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
    if not _col("users", "username"):
        op.add_column("users", sa.Column("username", sa.String(32), nullable=True))
        op.create_unique_constraint("uq_users_username", "users", ["username"])
        op.create_index("ix_users_username", "users", ["username"])

    if not _col("users", "bio"):
        op.add_column("users", sa.Column("bio", sa.String(200), nullable=True))

    if not _col("users", "avatar_media_id"):
        op.add_column(
            "users",
            sa.Column(
                "avatar_media_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("media.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )

    if not _col("users", "last_seen_at"):
        op.add_column(
            "users",
            sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        )

    if not _tbl("privacy_settings"):
        op.create_table(
            "privacy_settings",
            sa.Column(
                "user_id",
                sa.Integer(),
                sa.ForeignKey("users.id", ondelete="CASCADE"),
                primary_key=True,
            ),
            sa.Column(
                "last_seen",
                sa.Enum("everyone", "friends", "nobody", name="visibility", create_type=False),
                nullable=False,
                server_default="everyone",
            ),
            sa.Column(
                "avatar",
                sa.Enum("everyone", "friends", "nobody", name="visibility", create_type=False),
                nullable=False,
                server_default="everyone",
            ),
        )


def downgrade() -> None:
    op.drop_table("privacy_settings")
    op.execute("DROP TYPE IF EXISTS visibility")

    op.drop_index("ix_users_username", table_name="users")
    op.drop_constraint("uq_users_username", "users", type_="unique")
    op.drop_column("users", "last_seen_at")
    op.drop_column("users", "avatar_media_id")
    op.drop_column("users", "bio")
    op.drop_column("users", "username")
