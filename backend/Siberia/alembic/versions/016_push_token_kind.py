"""push_tokens: add kind column (apns vs voip)

Revision ID: 016_push_token_kind
Revises: 015_calls
Create Date: 2026-05-18
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "016_push_token_kind"
down_revision: Union[str, None] = "015_calls"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ENUM создаём отдельно чтобы можно было использовать в add_column без create_type
    pushtokenkind = sa.Enum("apns", "voip", "fcm", name="pushtokenkind")
    pushtokenkind.create(op.get_bind(), checkfirst=True)

    op.add_column(
        "push_tokens",
        sa.Column("kind",
                  sa.Enum("apns", "voip", "fcm", name="pushtokenkind", create_type=False),
                  nullable=False, server_default="apns"),
    )
    # Заодно делаем (user_id, kind) индекс — диспетчеру нужно быстро находить
    # все VoIP-токены пользователя
    op.create_index("ix_push_tokens_user_kind", "push_tokens", ["user_id", "kind"])


def downgrade() -> None:
    op.drop_index("ix_push_tokens_user_kind", table_name="push_tokens")
    op.drop_column("push_tokens", "kind")
    op.execute("DROP TYPE IF EXISTS pushtokenkind")
