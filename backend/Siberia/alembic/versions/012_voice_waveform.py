"""voice_waveform: add waveform JSONB column to media

Revision ID: 012_voice_waveform
Revises: 011_invisible_mode
Create Date: 2026-05-16
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB


revision: str = "012_voice_waveform"
down_revision: Union[str, None] = "011_invisible_mode"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("media", sa.Column("waveform", JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("media", "waveform")
