"""blocks table and messages_from privacy column

Revision ID: 005_friends_blocks
Revises: 004_profile
Create Date: 2026-04-19
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "005_friends_blocks"
down_revision: Union[str, None] = "004_profile"
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
    if not _tbl("blocks"):
        op.create_table(
            "blocks",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column(
                "blocker_id",
                sa.Integer(),
                sa.ForeignKey("users.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "blocked_id",
                sa.Integer(),
                sa.ForeignKey("users.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.func.now(),
            ),
            sa.UniqueConstraint("blocker_id", "blocked_id", name="uq_block"),
        )
        op.create_index("ix_blocks_blocker_id", "blocks", ["blocker_id"])
        op.create_index("ix_blocks_blocked_id", "blocks", ["blocked_id"])

    if not _col("privacy_settings", "messages_from"):
        op.add_column(
            "privacy_settings",
            sa.Column(
                "messages_from",
                sa.Enum("everyone", "friends", "nobody", name="visibility", create_type=False),
                nullable=False,
                server_default="everyone",
            ),
        )


def downgrade() -> None:
    op.drop_column("privacy_settings", "messages_from")
    op.drop_index("ix_blocks_blocked_id", table_name="blocks")
    op.drop_index("ix_blocks_blocker_id", table_name="blocks")
    op.drop_table("blocks")
