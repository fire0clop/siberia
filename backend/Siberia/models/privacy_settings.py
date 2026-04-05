import enum

from sqlalchemy import Column, Integer, ForeignKey, Enum, Boolean

from db import Base


class Visibility(str, enum.Enum):
    everyone = "everyone"
    friends = "friends"
    nobody = "nobody"


class PrivacySetting(Base):
    __tablename__ = "privacy_settings"

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    last_seen = Column(
        Enum(Visibility),
        nullable=False,
        default=Visibility.everyone,
        server_default="everyone",
    )
    avatar = Column(
        Enum(Visibility),
        nullable=False,
        default=Visibility.everyone,
        server_default="everyone",
    )
    # Who can start a new private chat / send first message
    messages_from = Column(
        Enum(Visibility),
        nullable=False,
        default=Visibility.everyone,
        server_default="everyone",
    )
    # "Невидимый режим" — пользователь скрывает online-статус ото всех,
    # КРОМЕ человека с которым у него прямо сейчас открыт чат.
    invisible_mode = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )
