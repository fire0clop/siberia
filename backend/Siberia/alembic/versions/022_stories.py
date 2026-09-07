"""Stories: эфемерные медиа-посты (24 часа) + отметки просмотров

Revision ID: 022_stories
Revises: 021_link_preview
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID


revision: str = "022_stories"
down_revision: Union[str, None] = "021_link_preview"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "stories",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("media_id", UUID(as_uuid=True),
                  sa.ForeignKey("media.id", ondelete="CASCADE"), nullable=False),
        sa.Column("caption", sa.String(200), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()"), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False, index=True),
    )

    op.create_table(
        "story_views",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("story_id", sa.Integer,
                  sa.ForeignKey("stories.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("user_id", sa.Integer,
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("viewed_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("story_id", "user_id", name="uq_story_view"),
    )


def downgrade() -> None:
    op.drop_table("story_views")
    op.drop_table("stories")
