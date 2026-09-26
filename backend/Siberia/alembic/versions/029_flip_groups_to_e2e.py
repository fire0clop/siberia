"""Групповое E2E (стадия 3b-3): флип существующих групп в E2E + вайп истории

Активирует групповое шифрование. Существующие группы помечаем is_e2e=true и
удаляем их старую ОТКРЫТУЮ пользовательскую историю (как для DM в стадии 2).
Системные сообщения (type=system) — метаданные, генерятся сервером и остаются
(нужны для связности истории группы). Каналы и «Избранное» не трогаем.

Литералы enum сравниваем через ::text — Postgres запрещает использовать
значение enum в той же транзакции, где оно было добавлено (алембик прогоняет
всю цепочку одной транзакцией на свежей БД).

Revision ID: 029_flip_groups_to_e2e
Revises: 028_group_e2e_sender_keys
Create Date: 2026-09-26
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "029_flip_groups_to_e2e"
down_revision: Union[str, None] = "028_group_e2e_sender_keys"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()

    # Отложенные сообщения групп — открытый текст, ещё не доставлены.
    conn.execute(sa.text(
        "DELETE FROM scheduled_messages WHERE chat_id IN "
        "(SELECT id FROM chats WHERE type::text = 'group')"
    ))

    # Старая открытая пользовательская история групп (кроме системных).
    conn.execute(sa.text(
        "DELETE FROM messages WHERE chat_id IN "
        "(SELECT id FROM chats WHERE type::text = 'group') "
        "AND type::text != 'system' AND encrypted_payload IS NULL"
    ))

    # Помечаем группы шифрованными.
    conn.execute(sa.text("UPDATE chats SET is_e2e = true WHERE type::text = 'group'"))


def downgrade() -> None:
    conn = op.get_bind()
    conn.execute(sa.text("UPDATE chats SET is_e2e = false WHERE type::text = 'group'"))
