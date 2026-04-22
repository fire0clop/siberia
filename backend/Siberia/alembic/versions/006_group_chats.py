"""group chat support: chat type, member roles, system messages

Revision ID: 006_group_chats
Revises: 005_friends_blocks
Create Date: 2026-04-19
"""
from typing import Sequence, Union
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from alembic import op

revision: str = "006_group_chats"
down_revision: Union[str, None] = "005_friends_blocks"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _col(table, col):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.columns WHERE table_name = :t AND column_name = :c AND table_schema = 'public'"),
        {"t": table, "c": col},
    )
    return r.fetchone() is not None


def upgrade() -> None:
    # New enums (IF NOT EXISTS guard — type may already exist from create_all in 001)
    op.execute("""DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chattype') THEN
            CREATE TYPE chattype AS ENUM ('private', 'group');
        END IF;
    END $$""")
    op.execute("""DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'memberrole') THEN
            CREATE TYPE memberrole AS ENUM ('owner', 'admin', 'member');
        END IF;
    END $$""")
    op.execute("""DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'messagetype') THEN
            CREATE TYPE messagetype AS ENUM ('text', 'system');
        END IF;
    END $$""")

    # Extend existing chatupdateeventtype with new values
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'member_added'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'member_removed'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'member_left'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'chat_updated'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'role_changed'")

    if not _col("chats", "type"):
        op.add_column("chats", sa.Column("type", sa.Enum("private", "group", name="chattype", create_type=False), nullable=False, server_default="private"))
    if not _col("chats", "avatar_media_id"):
        op.add_column("chats", sa.Column("avatar_media_id", postgresql.UUID(as_uuid=True), nullable=True))
        op.create_foreign_key("fk_chats_avatar_media_id", "chats", "media", ["avatar_media_id"], ["id"], ondelete="SET NULL")
    if not _col("chats", "description"):
        op.add_column("chats", sa.Column("description", sa.String(255), nullable=True))
    if not _col("chats", "max_members"):
        op.add_column("chats", sa.Column("max_members", sa.Integer(), nullable=False, server_default="200"))
    if not _col("chats", "invite_link"):
        op.add_column("chats", sa.Column("invite_link", sa.String(32), nullable=True))
        op.create_unique_constraint("uq_chats_invite_link", "chats", ["invite_link"])
        op.create_index("ix_chats_invite_link", "chats", ["invite_link"])

    if not _col("chat_members", "role"):
        op.add_column("chat_members", sa.Column("role", sa.Enum("owner", "admin", "member", name="memberrole", create_type=False), nullable=False, server_default="member"))
    if not _col("chat_members", "joined_at"):
        op.add_column("chat_members", sa.Column("joined_at", sa.DateTime(timezone=True), server_default=sa.func.now()))

    if not _col("messages", "type"):
        op.add_column("messages", sa.Column("type", sa.Enum("text", "system", name="messagetype", create_type=False), nullable=False, server_default="text"))


def downgrade() -> None:
    op.drop_column("messages", "type")
    op.drop_column("chat_members", "joined_at")
    op.drop_column("chat_members", "role")
    op.drop_index("ix_chats_invite_link", table_name="chats")
    op.drop_constraint("uq_chats_invite_link", "chats", type_="unique")
    op.drop_column("chats", "invite_link")
    op.drop_column("chats", "max_members")
    op.drop_column("chats", "description")
    op.drop_constraint("fk_chats_avatar_media_id", "chats", type_="foreignkey")
    op.drop_column("chats", "avatar_media_id")
    op.drop_column("chats", "type")
    op.execute("DROP TYPE IF EXISTS chattype")
    op.execute("DROP TYPE IF EXISTS memberrole")
    op.execute("DROP TYPE IF EXISTS messagetype")
