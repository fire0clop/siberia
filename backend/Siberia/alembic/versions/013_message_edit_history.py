"""message_edit_history: snapshot table of previous text versions

Revision ID: 013_message_edit_history
Revises: 012_voice_waveform
Create Date: 2026-05-16
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "013_message_edit_history"
down_revision: Union[str, None] = "012_voice_waveform"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "message_edit_history",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "message_id",
            sa.BigInteger,
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("text", sa.Text, nullable=True),
        sa.Column(
            "edited_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
    )
    op.create_index(
        "ix_message_edit_history_msg_at",
        "message_edit_history",
        ["message_id", "edited_at"],
    )
    op.create_index(
        "ix_message_edit_history_message_id",
        "message_edit_history",
        ["message_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_message_edit_history_message_id", table_name="message_edit_history")
    op.drop_index("ix_message_edit_history_msg_at", table_name="message_edit_history")
    op.drop_table("message_edit_history")
