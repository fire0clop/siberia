"""Стадия 2 E2E: удаление старой открытой истории личных чатов

С этого момента личные чаты (type=private) становятся end-to-end: сервер
хранит только шифроблобы. Ранее накопленный plaintext в приватных DM больше
не должен лежать в базе — удаляем его. Секретные чаты (уже шифрованы),
группы, каналы и «Избранное» не трогаем.

Удаляются строки messages в private-чатах, где encrypted_payload IS NULL
(т.е. открытый текст/медиа). Дочерние строки (реакции, статусы, история
правок) уходят по ON DELETE CASCADE; chats.last_message_id/pinned_message_id
и self-ссылки (reply/forward) — по ON DELETE SET NULL. Отдельно чистим
неотправленные отложенные сообщения приватных чатов (там тоже plaintext).

Revision ID: 026_wipe_plaintext_dm_history
Revises: 025_encrypt_sensitive_fields
Create Date: 2026-09-25
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "026_wipe_plaintext_dm_history"
down_revision: Union[str, None] = "025_encrypt_sensitive_fields"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()

    # Отложенные (ещё не доставленные) сообщения приватных чатов — plaintext.
    conn.execute(sa.text(
        "DELETE FROM scheduled_messages "
        "WHERE chat_id IN (SELECT id FROM chats WHERE type = 'private')"
    ))

    # Открытая история приватных DM. encrypted_payload IS NULL отсекает
    # уже-шифрованные сообщения (если такие появятся до наката миграции).
    conn.execute(sa.text(
        "DELETE FROM messages "
        "WHERE chat_id IN (SELECT id FROM chats WHERE type = 'private') "
        "AND encrypted_payload IS NULL"
    ))


def downgrade() -> None:
    # Необратимо: удалённый plaintext восстановить нельзя.
    pass
