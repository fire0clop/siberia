import uuid
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from models.media import MediaType
from services.media_service import get_media_url, upload_media

router = APIRouter(prefix="/media", tags=["Media"])


@router.post("/upload")
async def upload(
    file: UploadFile = File(...),
    type: MediaType = Form(...),
    duration_sec: Optional[int] = Form(None),
    waveform: Optional[str] = Form(None),   # JSON-кодированный массив float'ов
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Upload a media file. Returns the media object with its ID.
    После upload — прикрепляем media_id к сообщению через POST /chats/{id}/messages.

    Для voice/audio клиент может передать `waveform` — JSON-массив амплитуд (0..1)
    для отрисовки бар-визуализации у получателя.
    """
    import json
    parsed_waveform = None
    if waveform:
        try:
            arr = json.loads(waveform)
            if isinstance(arr, list) and all(isinstance(x, (int, float)) for x in arr):
                parsed_waveform = [float(x) for x in arr][:200]  # cap 200 bars
        except (json.JSONDecodeError, TypeError, ValueError):
            parsed_waveform = None

    media = await upload_media(
        db,
        uploader_id=current["user"].id,
        media_type=type,
        file=file,
        duration_sec=duration_sec,
        waveform=parsed_waveform,
    )
    return {
        "id": str(media.id),
        "type": media.type.value,
        "mime_type": media.mime_type,
        "size_bytes": media.size_bytes,
        "duration_sec": media.duration_sec,
        "width": media.width,
        "height": media.height,
        "original_name": media.original_name,
        "waveform": media.waveform,
    }


@router.get("/{media_id}/url")
async def get_url(
    media_id: uuid.UUID,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get a short-lived presigned URL for a media file."""
    return await get_media_url(db, media_id, current["user"].id)
