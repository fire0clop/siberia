"""Архив чатов (chat_members.archived_at) + пользовательские папки

Архив — per-user отметка на членстве: чат скрывается из основного списка,
но история и доставка не трогаются. Папки — именованные наборы чатов
пользователя (chat_folders + M2M chat_folder_items).

Revision ID: 020_archive_and_folders
Revises: 019_text_entities
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "020_archive_and_folders"
down_revision: Union[str, None] = "019_text_entities"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "chat_members",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )

    op.create_table(
        "chat_folders",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("name", sa.String(50), nullable=False),
        sa.Column("position", sa.Integer, nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()"), nullable=False),
    )

    op.create_table(
        "chat_folder_items",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("folder_id", sa.Integer,
                  sa.ForeignKey("chat_folders.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("chat_id", sa.Integer,
                  sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.UniqueConstraint("folder_id", "chat_id", name="uq_folder_chat"),
    )


def downgrade() -> None:
    op.drop_table("chat_folder_items")
    op.drop_table("chat_folders")
    op.drop_column("chat_members", "archived_at")
