"""media table and messages.media_id

Revision ID: 003_media
Revises: 002_push_mute
Create Date: 2026-04-19
"""
from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from alembic import op

revision: str = "003_media"
down_revision: Union[str, None] = "002_push_mute"
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
    if not _tbl("media"):
        op.create_table(
            "media",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "uploader_id",
                sa.Integer(),
                sa.ForeignKey("users.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "type",
                sa.Enum(
                    "image", "video", "voice", "video_note", "document", "audio",
                    name="mediatype", create_type=False,
                ),
                nullable=False,
            ),
            sa.Column("mime_type", sa.String(128), nullable=False),
            sa.Column("size_bytes", sa.BigInteger(), nullable=False),
            sa.Column("s3_key", sa.String(512), nullable=False),
            sa.Column("thumbnail_s3_key", sa.String(512), nullable=True),
            sa.Column("duration_sec", sa.Integer(), nullable=True),
            sa.Column("width", sa.Integer(), nullable=True),
            sa.Column("height", sa.Integer(), nullable=True),
            sa.Column("original_name", sa.String(512), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.func.now(),
            ),
        )
        op.create_index("ix_media_uploader_id", "media", ["uploader_id"])

    if not _col("messages", "media_id"):
        op.add_column(
            "messages",
            sa.Column(
                "media_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("media.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )
        op.create_index("ix_messages_media_id", "messages", ["media_id"])


def downgrade() -> None:
    op.drop_index("ix_messages_media_id", table_name="messages")
    op.drop_column("messages", "media_id")
    op.drop_index("ix_media_uploader_id", table_name="media")
    op.drop_table("media")
    op.execute("DROP TYPE IF EXISTS mediatype")
