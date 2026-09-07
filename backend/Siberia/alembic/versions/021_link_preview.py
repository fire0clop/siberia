"""messages.link_preview — OG-превью первой ссылки сообщения

{url, title, description, image_url, site_name} | null.
Заполняется асинхронно ARQ-воркером после отправки.

Revision ID: 021_link_preview
Revises: 020_archive_and_folders
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB


revision: str = "021_link_preview"
down_revision: Union[str, None] = "020_archive_and_folders"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("messages", sa.Column("link_preview", JSONB, nullable=True))


def downgrade() -> None:
    op.drop_column("messages", "link_preview")
