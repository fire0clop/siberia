import os
import uuid as _uuid
from typing import Optional

from fastapi import HTTPException, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import exists

from models.media import Media, MediaType
from models.message import Message
from models.chat_member import ChatMember
from services.s3 import upload_bytes, presigned_url
from services.thumbnail import make_image_thumbnail, get_image_dimensions, make_video_thumbnail
from utils import redis as redis_utils

# Presigned URLs are valid for 1 hour on MinIO; we cache them for 50 min.
_URL_CACHE_TTL = 3000  # seconds

# (allowed MIME set, max bytes). Empty set = any MIME accepted.
_ALLOWED: dict[MediaType, tuple[set[str], int]] = {
    MediaType.image: (
        {
            "image/jpeg", "image/jpg", "image/png", "image/webp",
            "image/gif", "image/bmp", "image/tiff", "image/tif",
            "image/heic", "image/heif", "image/avif", "image/svg+xml",
        },
        40 * 1024 * 1024,
    ),
    MediaType.video: (
        {
            "video/mp4", "video/quicktime", "video/webm",
            "video/x-msvideo", "video/avi", "video/mkv",
            "video/x-matroska", "video/3gpp", "video/mpeg",
        },
        500 * 1024 * 1024,
    ),
    MediaType.voice: (
        {"audio/ogg", "audio/mp4", "audio/mpeg", "audio/m4a", "audio/aac", "audio/x-m4a"},
        25 * 1024 * 1024,
    ),
    MediaType.video_note: (
        {"video/mp4", "video/quicktime"},
        50 * 1024 * 1024,
    ),
    MediaType.document: (
        set(),  # any MIME — PDF, DOCX, XLSX, ZIP, etc.
        200 * 1024 * 1024,
    ),
    MediaType.audio: (
        {
            "audio/mpeg", "audio/mp3", "audio/ogg", "audio/mp4",
            "audio/m4a", "audio/x-m4a", "audio/flac", "audio/wav",
            "audio/x-wav", "audio/aac", "audio/x-aac",
        },
        100 * 1024 * 1024,
    ),
}

_MIME_EXT: dict[str, str] = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/bmp": ".bmp",
    "image/tiff": ".tiff",
    "image/tif": ".tif",
    "image/heic": ".heic",
    "image/heif": ".heif",
    "image/avif": ".avif",
    "image/svg+xml": ".svg",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "video/x-msvideo": ".avi",
    "video/avi": ".avi",
    "video/x-matroska": ".mkv",
    "video/mkv": ".mkv",
    "video/3gpp": ".3gp",
    "video/mpeg": ".mpeg",
    "audio/ogg": ".ogg",
    "audio/mp4": ".m4a",
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/m4a": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/x-aac": ".aac",
    "audio/flac": ".flac",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
}


def _ext(content_type: str, filename: Optional[str]) -> str:
    if filename:
        _, ext = os.path.splitext(filename)
        if ext:
            return ext.lower()
    return _MIME_EXT.get(content_type, "")


async def upload_media(
    db: AsyncSession,
    uploader_id: int,
    media_type: MediaType,
    file: UploadFile,
    duration_sec: Optional[int] = None,
    waveform: Optional[list[float]] = None,
) -> Media:
    allowed_mimes, max_bytes = _ALLOWED[media_type]
    content_type = (file.content_type or "application/octet-stream").split(";")[0].strip()

    if allowed_mimes and content_type not in allowed_mimes:
        raise HTTPException(
            status_code=415,
            detail=f"Unsupported MIME type '{content_type}' for {media_type.value}",
        )

    data = await file.read()
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"File too large (max {max_bytes // (1024 * 1024)} MB)",
        )
    if len(data) == 0:
        raise HTTPException(status_code=400, detail="Empty file")

    media_id = _uuid.uuid4()
    ext = _ext(content_type, file.filename)
    s3_key = f"media/{media_type.value}/{media_id}{ext}"

    await upload_bytes(s3_key, data, content_type)

    thumb_key: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None
    original_name: Optional[str] = None

    if media_type == MediaType.image:
        w, h = await get_image_dimensions(data)
        width, height = (w or None), (h or None)
        thumb = await make_image_thumbnail(data)
        if thumb:
            thumb_key = f"media/thumbs/{media_id}.jpg"
            await upload_bytes(thumb_key, thumb, "image/jpeg")

    elif media_type in (MediaType.video, MediaType.video_note):
        thumb = await make_video_thumbnail(data)
        if thumb:
            thumb_key = f"media/thumbs/{media_id}.jpg"
            await upload_bytes(thumb_key, thumb, "image/jpeg")
        original_name = file.filename

    elif media_type in (MediaType.document, MediaType.audio):
        original_name = file.filename

    media = Media(
        id=media_id,
        uploader_id=uploader_id,
        type=media_type,
        mime_type=content_type,
        size_bytes=len(data),
        s3_key=s3_key,
        thumbnail_s3_key=thumb_key,
        duration_sec=duration_sec,
        width=width,
        height=height,
        original_name=original_name,
        waveform=waveform if media_type in (MediaType.voice, MediaType.audio) else None,
    )
    db.add(media)
    await db.commit()
    await db.refresh(media)
    return media


async def get_media_url(
    db: AsyncSession,
    media_id: _uuid.UUID,
    user_id: int,
) -> dict:
    media = await db.get(Media, media_id)
    if not media:
        raise HTTPException(status_code=404, detail="Media not found")

    if media.uploader_id != user_id:
        # Allow if user is a member of any chat that references this media
        stmt = select(
            exists(
                select(Message.id)
                .join(ChatMember, ChatMember.chat_id == Message.chat_id)
                .where(
                    Message.media_id == media_id,
                    ChatMember.user_id == user_id,
                )
            )
        )
        result = await db.execute(stmt)
        if not result.scalar():
            raise HTTPException(status_code=403, detail="Access denied")

    cache_key = f"media:url:{media_id}"
    import json as _json
    cached = await redis_utils.cache_get(cache_key)
    if cached:
        return _json.loads(cached)

    url = await presigned_url(media.s3_key)
    thumb_url = (
        await presigned_url(media.thumbnail_s3_key)
        if media.thumbnail_s3_key
        else None
    )

    result = {
        "id": str(media.id),
        "type": media.type.value,
        "mime_type": media.mime_type,
        "size_bytes": media.size_bytes,
        "url": url,
        "thumbnail_url": thumb_url,
        "duration_sec": media.duration_sec,
        "width": media.width,
        "height": media.height,
        "original_name": media.original_name,
        "waveform": media.waveform,
    }
    await redis_utils.cache_set(cache_key, _json.dumps(result), ttl=_URL_CACHE_TTL)
    return result
