import enum
from datetime import datetime, timezone

from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, Enum
from sqlalchemy.orm import relationship

from db import Base


class PushPlatform(str, enum.Enum):
    ios = "ios"
    android = "android"


class PushTokenKind(str, enum.Enum):
    """Тип токена:
    - apns: обычный APNs alert push (новые сообщения, бейдж)
    - voip: PushKit VoIP push (звонки — мгновенная доставка, может разбудить
            убитое приложение, обязан в ответ репортить в CallKit)
    - fcm:  Firebase Cloud Messaging (Android)
    """
    apns = "apns"
    voip = "voip"
    fcm = "fcm"


class PushToken(Base):
    __tablename__ = "push_tokens"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    session_id = Column(Integer, ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    device_token = Column(String(512), nullable=False, unique=True)
    platform = Column(Enum(PushPlatform), nullable=False)
    kind = Column(Enum(PushTokenKind), nullable=False,
                  default=PushTokenKind.apns, server_default="apns")
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc),
                        onupdate=lambda: datetime.now(timezone.utc))

    user = relationship("User")
    session = relationship("Session")
