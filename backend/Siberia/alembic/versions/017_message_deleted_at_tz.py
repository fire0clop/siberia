"""messages.deleted_at: TIMESTAMP -> TIMESTAMPTZ

Колонка была объявлена без timezone, в отличие от created_at/edited_at.
soft_delete_message пишет aware-datetime, и asyncpg отвечал DataError
("can't subtract offset-naive and offset-aware datetimes") — DELETE /messages
падал 500.

Revision ID: 017_message_deleted_at_tz
Revises: 016_push_token_kind
Create Date: 2026-07-04
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "017_message_deleted_at_tz"
down_revision: Union[str, None] = "016_push_token_kind"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column(
        "messages",
        "deleted_at",
        type_=sa.DateTime(timezone=True),
        postgresql_using="deleted_at AT TIME ZONE 'UTC'",
    )


def downgrade() -> None:
    op.alter_column(
        "messages",
        "deleted_at",
        type_=sa.DateTime(timezone=False),
        postgresql_using="deleted_at AT TIME ZONE 'UTC'",
    )
