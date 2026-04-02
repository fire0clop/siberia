import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, BigInteger, Integer, String, Enum, DateTime, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, JSONB

from db import Base


class MediaType(str, enum.Enum):
    image = "image"
    video = "video"
    voice = "voice"
    video_note = "video_note"
    document = "document"
    audio = "audio"


class Media(Base):
    __tablename__ = "media"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    uploader_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    type = Column(Enum(MediaType), nullable=False)
    mime_type = Column(String(128), nullable=False)
    size_bytes = Column(BigInteger, nullable=False)
    s3_key = Column(String(512), nullable=False)
    thumbnail_s3_key = Column(String(512), nullable=True)
    duration_sec = Column(Integer, nullable=True)
    width = Column(Integer, nullable=True)
    height = Column(Integer, nullable=True)
    original_name = Column(String(512), nullable=True)
    # Для voice/audio: массив float-амплитуд 0..1 для отрисовки waveform.
    # Записывается клиентом при upload; на сервере не считается.
    waveform = Column(JSONB, nullable=True)
    created_at = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
