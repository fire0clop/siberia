from typing import Optional

import aioboto3

from config import settings
from utils.redis import cache_get, cache_set

_session = aioboto3.Session()

# Кэшируем presigned URL в Redis на 50 минут (TTL самого URL = 3600, оставляем запас)
_URL_CACHE_TTL = 50 * 60


def _client():
    return _session.client(
        "s3",
        endpoint_url=settings.S3_ENDPOINT or None,
        aws_access_key_id=settings.S3_KEY_ID,
        aws_secret_access_key=settings.S3_SECRET,
        region_name=settings.S3_REGION or "auto",
    )


async def upload_bytes(key: str, data: bytes, content_type: str) -> None:
    async with _client() as s3:
        await s3.put_object(
            Bucket=settings.S3_BUCKET,
            Key=key,
            Body=data,
            ContentType=content_type,
        )


async def presigned_url(key: str, expires: int = 3600) -> str:
    # Каждый вызов generate_presigned_url — отдельный SDK call с подписью.
    # На активной галерее это тормозит. Кешируем в Redis на 50 мин.
    cache_key = f"media:url:{key}"
    cached = await cache_get(cache_key)
    if cached:
        return cached

    async with _client() as s3:
        url = await s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": settings.S3_BUCKET, "Key": key},
            ExpiresIn=expires,
        )
    if settings.S3_PUBLIC_URL and settings.S3_ENDPOINT:
        url = url.replace(settings.S3_ENDPOINT, settings.S3_PUBLIC_URL, 1)
    await cache_set(cache_key, url, ttl=_URL_CACHE_TTL)
    return url


async def delete_object(key: str) -> None:
    async with _client() as s3:
        await s3.delete_object(Bucket=settings.S3_BUCKET, Key=key)
