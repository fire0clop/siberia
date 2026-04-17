import asyncio
import io
import logging
import os
import tempfile
from typing import Optional

logger = logging.getLogger(__name__)


async def make_image_thumbnail(data: bytes, max_size: int = 320) -> Optional[bytes]:
    try:
        from PIL import Image
    except ImportError:
        logger.warning("PIL/Pillow not installed; image thumbnails disabled")
        return None

    def _process() -> Optional[bytes]:
        try:
            img = Image.open(io.BytesIO(data))
            img.thumbnail((max_size, max_size))
            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGB")
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=85, optimize=True)
            return out.getvalue()
        except Exception as exc:
            logger.exception("Image thumbnail generation failed: %s", exc)
            return None

    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _process)


async def get_image_dimensions(data: bytes) -> tuple[int, int]:
    try:
        from PIL import Image

        def _get() -> tuple[int, int]:
            img = Image.open(io.BytesIO(data))
            return img.size

        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, _get)
    except Exception as exc:
        logger.exception("Failed to read image dimensions: %s", exc)
        return 0, 0


async def make_video_thumbnail(data: bytes, max_size: int = 320) -> Optional[bytes]:
    """Extract first frame via ffmpeg; returns None if ffmpeg is unavailable."""
    tmp_in = tmp_out = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as fin:
            fin.write(data)
            tmp_in = fin.name

        tmp_out = tmp_in + "_thumb.jpg"

        proc = await asyncio.create_subprocess_exec(
            "ffmpeg",
            "-y",
            "-i",
            tmp_in,
            "-vframes",
            "1",
            "-vf",
            f"scale='min({max_size},iw)':'min({max_size},ih)':force_original_aspect_ratio=decrease",
            tmp_out,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

        if proc.returncode == 0 and os.path.exists(tmp_out):
            with open(tmp_out, "rb") as f:
                return f.read()
        else:
            logger.warning("ffmpeg returned code=%s for video thumbnail", proc.returncode)
    except FileNotFoundError:
        logger.warning("ffmpeg not installed; video thumbnails disabled")
    except Exception as exc:
        logger.exception("Video thumbnail generation failed: %s", exc)
    finally:
        for p in (tmp_in, tmp_out):
            if p:
                try:
                    os.unlink(p)
                except Exception as exc:
                    logger.debug("Failed to unlink temp file %s: %s", p, exc)
    return None
