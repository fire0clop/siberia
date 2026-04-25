"""calls: voice and video call history

Revision ID: 015_calls
Revises: 014_message_edited_at_tz
Create Date: 2026-05-17
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "015_calls"
down_revision: Union[str, None] = "014_message_edited_at_tz"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # SQLAlchemy сам создаст enum-типы calltype и callstatus при create_table —
    # отдельный DO $$ BEGIN не нужен (он только бил с авто-CREATE TYPE внутри одной транзакции).
    op.create_table(
        "calls",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("caller_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("callee_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("chat_id", sa.Integer,
                  sa.ForeignKey("chats.id", ondelete="SET NULL"), nullable=True),
        sa.Column("type",
                  sa.Enum("audio", "video", name="calltype"),
                  nullable=False, server_default="audio"),
        sa.Column("status",
                  sa.Enum("ringing", "active", "ended", "declined", "missed", "cancelled",
                          name="callstatus"),
                  nullable=False, server_default="ringing"),
        sa.Column("started_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ended_at",    sa.DateTime(timezone=True), nullable=True),
        sa.Column("duration_seconds", sa.Integer, nullable=True),
    )
    op.create_index("ix_calls_caller_id",      "calls", ["caller_id"])
    op.create_index("ix_calls_callee_id",      "calls", ["callee_id"])
    op.create_index("ix_calls_chat_id",        "calls", ["chat_id"])
    op.create_index("ix_calls_caller_started", "calls", ["caller_id", "started_at"])
    op.create_index("ix_calls_callee_started", "calls", ["callee_id", "started_at"])


def downgrade() -> None:
    op.drop_index("ix_calls_callee_started", table_name="calls")
    op.drop_index("ix_calls_caller_started", table_name="calls")
    op.drop_index("ix_calls_chat_id",        table_name="calls")
    op.drop_index("ix_calls_callee_id",      table_name="calls")
    op.drop_index("ix_calls_caller_id",      table_name="calls")
    op.drop_table("calls")
    op.execute("DROP TYPE IF EXISTS callstatus")
    op.execute("DROP TYPE IF EXISTS calltype")
