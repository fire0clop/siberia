"""invisible_mode: add invisible_mode column to privacy_settings

Revision ID: 011_invisible_mode
Revises: 010_indexes
Create Date: 2026-05-16
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "011_invisible_mode"
down_revision: Union[str, None] = "010_indexes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "privacy_settings",
        sa.Column(
            "invisible_mode",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )


def downgrade() -> None:
    op.drop_column("privacy_settings", "invisible_mode")
