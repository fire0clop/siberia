"""rich messaging: reactions, forwarding, mentions, pinned, drafts, scheduled

Revision ID: 007_rich_messages
Revises: 006_group_chats
Create Date: 2026-04-19
"""
from typing import Sequence, Union
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from alembic import op

revision: str = "007_rich_messages"
down_revision: Union[str, None] = "006_group_chats"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _tbl(name):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.tables WHERE table_name = :n AND table_schema = 'public'"),
        {"n": name},
    )
    return r.fetchone() is not None


def _col(table, col):
    r = op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.columns WHERE table_name = :t AND column_name = :c AND table_schema = 'public'"),
        {"t": table, "c": col},
    )
    return r.fetchone() is not None


def upgrade() -> None:
    if not _col("messages", "forwarded_from_message_id"):
        op.add_column("messages", sa.Column("forwarded_from_message_id", sa.BigInteger(), nullable=True))
    if not _col("messages", "forwarded_from_user_id"):
        op.add_column("messages", sa.Column("forwarded_from_user_id", sa.Integer(), nullable=True))
    if not _col("messages", "forwarded_from_chat_id"):
        op.add_column("messages", sa.Column("forwarded_from_chat_id", sa.Integer(), nullable=True))
    if not _col("messages", "mention_user_ids"):
        op.add_column("messages", sa.Column("mention_user_ids", postgresql.JSONB(), nullable=True))
    if not _col("messages", "send_at"):
        op.add_column("messages", sa.Column("send_at", sa.DateTime(timezone=True), nullable=True))

    if not _col("chats", "pinned_message_id"):
        op.add_column("chats", sa.Column("pinned_message_id", sa.BigInteger(), nullable=True))
        op.create_foreign_key(
            "fk_chats_pinned_message",
            "chats", "messages",
            ["pinned_message_id"], ["id"],
            ondelete="SET NULL",
        )

    op.execute("ALTER TYPE chattype ADD VALUE IF NOT EXISTS 'saved'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'reaction_update'")
    op.execute("ALTER TYPE chatupdateeventtype ADD VALUE IF NOT EXISTS 'message_pinned'")

    if not _tbl("message_reactions"):
        op.create_table(
            "message_reactions",
            sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
            sa.Column("message_id", sa.BigInteger(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("emoji", sa.String(8), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
            sa.UniqueConstraint("message_id", "user_id", name="uq_reaction_user_message"),
        )
        op.create_index("ix_message_reactions_message_id", "message_reactions", ["message_id"])
        op.create_index("ix_message_reactions_user_id", "message_reactions", ["user_id"])

    if not _tbl("chat_drafts"):
        op.create_table(
            "chat_drafts",
            sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
            sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("text", sa.String(4096), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
            sa.UniqueConstraint("chat_id", "user_id", name="uq_draft_chat_user"),
        )
        op.create_index("ix_chat_drafts_chat_id", "chat_drafts", ["chat_id"])
        op.create_index("ix_chat_drafts_user_id", "chat_drafts", ["user_id"])


def downgrade() -> None:
    op.drop_table("chat_drafts")
    op.drop_table("message_reactions")

    op.drop_constraint("fk_chats_pinned_message", "chats", type_="foreignkey")
    op.drop_column("chats", "pinned_message_id")

    op.drop_column("messages", "send_at")
    op.drop_column("messages", "mention_user_ids")
    op.drop_column("messages", "forwarded_from_chat_id")
    op.drop_column("messages", "forwarded_from_user_id")
    op.drop_column("messages", "forwarded_from_message_id")
