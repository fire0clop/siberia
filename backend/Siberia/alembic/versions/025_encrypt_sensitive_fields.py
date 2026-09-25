"""At-rest защита: хеширование рефреш-токенов + шифрование TOTP-секретов

Конвертирует существующие строки:
  sessions.refresh_token / prev_refresh_token → SHA-256 hex
  users.totp_secret (активные) → enc:v1:<base64>
Pending-секреты (pending:...) и NULL не трогаем.

Revision ID: 025_encrypt_sensitive_fields
Revises: 024_scheduled_messages_table
Create Date: 2026-09-25
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "025_encrypt_sensitive_fields"
down_revision: Union[str, None] = "024_scheduled_messages_table"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    import sys
    sys.path.insert(0, ".")
    from utils.secrets_crypto import hash_token, encrypt_secret, is_encrypted

    conn = op.get_bind()

    # Шифр TOTP длиннее base32-секрета — расширяем колонку
    op.alter_column("users", "totp_secret", type_=sa.String(255))

    # Рефреш-токены → хеши (и current, и prev)
    rows = conn.execute(sa.text(
        "SELECT id, refresh_token, prev_refresh_token FROM sessions"
    )).fetchall()
    for sid, rt, prev in rows:
        updates = {}
        # хеш детерминирован и 64 симв.; уже захешированные (ровно hex64) пропускаем
        if rt and not (len(rt) == 64 and all(c in "0123456789abcdef" for c in rt)):
            updates["rt"] = hash_token(rt)
        if prev and not (len(prev) == 64 and all(c in "0123456789abcdef" for c in prev)):
            updates["prev"] = hash_token(prev)
        if updates:
            conn.execute(
                sa.text(
                    "UPDATE sessions SET "
                    + ", ".join(f"{ 'refresh_token' if k=='rt' else 'prev_refresh_token' } = :{k}" for k in updates)
                    + " WHERE id = :id"
                ),
                {**updates, "id": sid},
            )

    # Активные TOTP-секреты → шифр
    users = conn.execute(sa.text(
        "SELECT id, totp_secret FROM users WHERE totp_secret IS NOT NULL"
    )).fetchall()
    for uid, secret in users:
        if secret.startswith("pending:") or is_encrypted(secret):
            continue
        conn.execute(
            sa.text("UPDATE users SET totp_secret = :s WHERE id = :id"),
            {"s": encrypt_secret(secret), "id": uid},
        )


def downgrade() -> None:
    # Необратимо: хеши токенов восстановить нельзя. TOTP-секреты можно было бы
    # расшифровать, но смешивать форматы на downgrade небезопасно — no-op.
    pass
