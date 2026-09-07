"""sessions: prev_refresh_token + rotated_at для grace-окна ротации

Строгая ротация refresh-токенов без row-lock ломалась на легитимной гонке:
два параллельных /auth/refresh с одним токеном оба проходили проверку,
и проигравший на следующем refresh триггерил reuse-детект — удалялись ВСЕ
сессии пользователя. Теперь ротация идёт под FOR UPDATE, а предыдущий токен
хранится и принимается в течение короткого grace-окна: опоздавший клиент
получает свежий access и ТЕКУЩИЙ refresh, обе стороны сходятся на одном
токене вместо взаимного отстрела.

Revision ID: 018_refresh_rotation_grace
Revises: 017_message_deleted_at_tz
Create Date: 2026-09-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "018_refresh_rotation_grace"
down_revision: Union[str, None] = "017_message_deleted_at_tz"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("sessions", sa.Column("prev_refresh_token", sa.String(), nullable=True))
    op.add_column("sessions", sa.Column("rotated_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("sessions", "rotated_at")
    op.drop_column("sessions", "prev_refresh_token")
