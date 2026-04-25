"""messages.edited_at: convert TIMESTAMP → TIMESTAMPTZ

Bug: edit_message() писал datetime с tzinfo=UTC в колонку TIMESTAMP WITHOUT TIME ZONE,
asyncpg падал на «can't subtract offset-naive and offset-aware datetimes».

Revision ID: 014_message_edited_at_tz
Revises: 013_message_edit_history
Create Date: 2026-05-17
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "014_message_edited_at_tz"
down_revision: Union[str, None] = "013_message_edit_history"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column(
        "messages",
        "edited_at",
        type_=sa.DateTime(timezone=True),
        existing_nullable=True,
        postgresql_using="edited_at AT TIME ZONE 'UTC'",
    )


def downgrade() -> None:
    op.alter_column(
        "messages",
        "edited_at",
        type_=sa.DateTime(timezone=False),
        existing_nullable=True,
    )
