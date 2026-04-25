"""indexes: performance indexes for hot query paths

Revision ID: 010_indexes
Revises: 009_channels
Create Date: 2026-04-19
"""
from typing import Sequence, Union
from alembic import op

revision: str = "010_indexes"
down_revision: Union[str, None] = "009_channels"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Messages: main pagination query (chat feed, newest-first)
    op.create_index(
        "ix_messages_chat_id_id_desc",
        "messages",
        ["chat_id", "id"],
        postgresql_ops={"id": "DESC"},
    )
    # Messages: scheduled delivery worker
    op.create_index(
        "ix_messages_send_at_partial",
        "messages",
        ["chat_id", "send_at"],
        postgresql_where="send_at IS NOT NULL",
    )
    # Chat members: user's chat list lookup
    op.create_index(
        "ix_chat_members_user_chat",
        "chat_members",
        ["user_id", "chat_id"],
    )
    # Login events: login history per user
    op.create_index(
        "ix_login_events_user_created",
        "login_events",
        ["user_id", "created_at"],
    )
    # Login events: new-device detection (ip+success filter)
    op.create_index(
        "ix_login_events_user_ip_success",
        "login_events",
        ["user_id", "ip", "success"],
    )


def downgrade() -> None:
    op.drop_index("ix_login_events_user_ip_success", table_name="login_events")
    op.drop_index("ix_login_events_user_created", table_name="login_events")
    op.drop_index("ix_chat_members_user_chat", table_name="chat_members")
    op.drop_index("ix_messages_send_at_partial", table_name="messages")
    op.drop_index("ix_messages_chat_id_id_desc", table_name="messages")
