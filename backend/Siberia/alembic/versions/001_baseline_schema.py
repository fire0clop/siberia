"""baseline schema

Revision ID: 001_baseline
Revises:
Create Date: 2026-04-05

"""
from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import text
from sqlalchemy.dialects import postgresql
from alembic import op

revision: str = "001_baseline"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # ── Enum types ────────────────────────────────────────────────────────────
    bind.execute(text("CREATE TYPE messagestatusenum AS ENUM ('sent', 'delivered', 'read')"))
    bind.execute(text("CREATE TYPE friendstatus AS ENUM ('pending', 'accepted', 'rejected')"))
    bind.execute(text(
        "CREATE TYPE chatupdateeventtype AS ENUM "
        "('message_new', 'message_edit', 'message_delete', 'read_receipt')"
    ))

    # ── users ─────────────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE users (
            id          SERIAL PRIMARY KEY,
            public_id   VARCHAR UNIQUE,
            email       VARCHAR NOT NULL UNIQUE,
            nickname    VARCHAR NOT NULL UNIQUE,
            password    VARCHAR NOT NULL,
            created_at  TIMESTAMPTZ DEFAULT now()
        )
    """))
    bind.execute(text("CREATE INDEX ix_users_public_id ON users (public_id)"))
    bind.execute(text("CREATE INDEX ix_users_email ON users (email)"))
    bind.execute(text("CREATE INDEX ix_users_nickname ON users (nickname)"))

    # ── sessions ──────────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE sessions (
            id            SERIAL PRIMARY KEY,
            user_id       INT REFERENCES users(id) ON DELETE CASCADE,
            refresh_token VARCHAR UNIQUE,
            device_id     VARCHAR,
            user_agent    VARCHAR,
            created_at    TIMESTAMPTZ DEFAULT now(),
            last_active   TIMESTAMPTZ DEFAULT now()
        )
    """))
    bind.execute(text("CREATE INDEX ix_sessions_refresh_token ON sessions (refresh_token)"))
    bind.execute(text("CREATE INDEX ix_sessions_device_id ON sessions (device_id)"))

    # ── chats (no last_message_id yet — add after messages) ───────────────────
    bind.execute(text("""
        CREATE TABLE chats (
            id          SERIAL PRIMARY KEY,
            title       VARCHAR,
            sync_seq    BIGINT NOT NULL DEFAULT 0,
            created_at  TIMESTAMPTZ DEFAULT now()
        )
    """))

    # ── messages ──────────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE messages (
            id                  BIGSERIAL PRIMARY KEY,
            chat_id             INT REFERENCES chats(id) ON DELETE CASCADE,
            user_id             INT REFERENCES users(id) ON DELETE CASCADE,
            text                VARCHAR,
            client_message_id   UUID,
            reply_to_message_id BIGINT REFERENCES messages(id) ON DELETE SET NULL,
            created_at          TIMESTAMPTZ DEFAULT now(),
            edited_at           TIMESTAMP,
            deleted_at          TIMESTAMP
        )
    """))
    bind.execute(text("CREATE INDEX ix_messages_chat_id ON messages (chat_id)"))
    bind.execute(text("CREATE INDEX ix_messages_user_id ON messages (user_id)"))
    bind.execute(text("CREATE INDEX ix_messages_client_message_id ON messages (client_message_id)"))
    bind.execute(text(
        "CREATE UNIQUE INDEX uq_message_client_idempotency ON messages "
        "(chat_id, user_id, client_message_id) WHERE client_message_id IS NOT NULL"
    ))
    bind.execute(text(
        "CREATE INDEX ix_messages_fts ON messages "
        "USING gin (to_tsvector('simple', coalesce(text, '')))"
    ))

    # ── chats.last_message_id ─────────────────────────────────────────────────
    bind.execute(text("ALTER TABLE chats ADD COLUMN last_message_id BIGINT REFERENCES messages(id) ON DELETE SET NULL"))

    # ── chat_members ──────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE chat_members (
            id      SERIAL PRIMARY KEY,
            user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            chat_id INT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            CONSTRAINT uq_chat_member UNIQUE (user_id, chat_id)
        )
    """))
    bind.execute(text("CREATE INDEX ix_chat_members_user_id ON chat_members (user_id)"))
    bind.execute(text("CREATE INDEX ix_chat_members_chat_id ON chat_members (chat_id)"))

    # ── message_statuses ──────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE message_statuses (
            id         SERIAL PRIMARY KEY,
            message_id BIGINT REFERENCES messages(id) ON DELETE CASCADE,
            user_id    INT REFERENCES users(id) ON DELETE CASCADE,
            status     messagestatusenum NOT NULL,
            CONSTRAINT uq_message_user UNIQUE (message_id, user_id)
        )
    """))
    bind.execute(text("CREATE INDEX ix_message_statuses_message_id ON message_statuses (message_id)"))
    bind.execute(text("CREATE INDEX ix_message_statuses_user_id ON message_statuses (user_id)"))

    # ── friends ───────────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE friends (
            id           SERIAL PRIMARY KEY,
            requester_id INT REFERENCES users(id) ON DELETE CASCADE,
            addressee_id INT REFERENCES users(id) ON DELETE CASCADE,
            status       friendstatus,
            CONSTRAINT uq_friend_request UNIQUE (requester_id, addressee_id)
        )
    """))
    bind.execute(text("CREATE INDEX ix_friends_requester_id ON friends (requester_id)"))
    bind.execute(text("CREATE INDEX ix_friends_addressee_id ON friends (addressee_id)"))

    # ── chat_updates ──────────────────────────────────────────────────────────
    bind.execute(text("""
        CREATE TABLE chat_updates (
            id         BIGSERIAL PRIMARY KEY,
            chat_id    INT REFERENCES chats(id) ON DELETE CASCADE,
            seq        BIGINT NOT NULL,
            event_type chatupdateeventtype NOT NULL,
            message_id BIGINT REFERENCES messages(id) ON DELETE SET NULL,
            payload    JSONB,
            created_at TIMESTAMPTZ DEFAULT now(),
            CONSTRAINT uq_chat_update_seq UNIQUE (chat_id, seq)
        )
    """))
    bind.execute(text("CREATE INDEX ix_chat_updates_chat_id ON chat_updates (chat_id)"))


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(text("DROP TABLE IF EXISTS chat_updates"))
    bind.execute(text("DROP TABLE IF EXISTS friends"))
    bind.execute(text("DROP TABLE IF EXISTS message_statuses"))
    bind.execute(text("DROP TABLE IF EXISTS chat_members"))
    bind.execute(text("ALTER TABLE chats DROP COLUMN IF EXISTS last_message_id"))
    bind.execute(text("DROP TABLE IF EXISTS messages"))
    bind.execute(text("DROP TABLE IF EXISTS chats"))
    bind.execute(text("DROP TABLE IF EXISTS sessions"))
    bind.execute(text("DROP TABLE IF EXISTS users"))
    bind.execute(text("DROP TYPE IF EXISTS chatupdateeventtype"))
    bind.execute(text("DROP TYPE IF EXISTS friendstatus"))
    bind.execute(text("DROP TYPE IF EXISTS messagestatusenum"))
