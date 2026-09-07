"""Отложенные сообщения: отдельная таблица вместо строк в messages

Архитектурный фикс: раньше scheduled-сообщение вставлялось в messages сразу
(id выдавался в момент планирования), из-за чего при доставке оно сортировалось
в глубину истории по старому id. Теперь до отправки оно живёт в
scheduled_messages, а НАСТОЯЩЕЕ сообщение создаётся воркером в момент
доставки — со свежим id и корректной позицией в ленте. Идемпотентность
доставки — через client_message_id (at-least-once + dedupe = effectively-once).

Revision ID: 024_scheduled_messages_table
Revises: 023_e2e_secret_chats
Create Date: 2026-09-08
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID


revision: str = "024_scheduled_messages_table"
down_revision: Union[str, None] = "023_e2e_secret_chats"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "scheduled_messages",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("chat_id", sa.Integer,
                  sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("user_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("text", sa.Text, nullable=True),
        sa.Column("text_entities", JSONB, nullable=True),
        sa.Column("media_id", UUID(as_uuid=True),
                  sa.ForeignKey("media.id", ondelete="SET NULL"), nullable=True),
        sa.Column("reply_to_message_id", sa.BigInteger, nullable=True),
        sa.Column("client_message_id", UUID(as_uuid=True), nullable=False, unique=True),
        sa.Column("send_at", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()"), nullable=False),
    )

    # Переносим ещё не отправленные scheduled-строки из messages
    op.execute("""
        INSERT INTO scheduled_messages
            (chat_id, user_id, text, text_entities, media_id,
             reply_to_message_id, client_message_id, send_at, created_at)
        SELECT chat_id, user_id, text, text_entities, media_id,
               reply_to_message_id,
               COALESCE(client_message_id, gen_random_uuid()),
               send_at, created_at
        FROM messages
        WHERE send_at IS NOT NULL AND deleted_at IS NULL
    """)
    op.execute("DELETE FROM messages WHERE send_at IS NOT NULL AND deleted_at IS NULL")


def downgrade() -> None:
    op.drop_table("scheduled_messages")
