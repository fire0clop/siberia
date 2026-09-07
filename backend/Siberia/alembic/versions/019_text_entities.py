"""messages.text_entities — разметка текста (bold/italic/code/spoiler…)

Telegram-модель: клиент парсит markdown в чистый текст + массив entities
[{type, offset, length}] (offset/length — в UTF-16 code units), сервер
хранит и валидирует. Рендер — на клиенте через AttributedString.

Revision ID: 019_text_entities
Revises: 018_refresh_rotation_grace
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB


revision: str = "019_text_entities"
down_revision: Union[str, None] = "018_refresh_rotation_grace"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("messages", sa.Column("text_entities", JSONB, nullable=True))


def downgrade() -> None:
    op.drop_column("messages", "text_entities")
