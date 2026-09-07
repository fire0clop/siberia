"""Link preview: выкачивание OG-тегов для URL в сообщениях.

Поток: create_message находит первый URL → ставит ARQ-задачу →
воркер безопасно скачивает страницу, парсит OG-теги, пишет
messages.link_preview и публикует событие link_preview в комнату чата.

Безопасность (SSRF): только http/https, резолвим хост и отвергаем
приватные/loopback/link-local адреса, редиректы проходим вручную
с той же проверкой, читаем не больше _MAX_BYTES, только text/html.
"""
from __future__ import annotations

import ipaddress
import json
import logging
import re
import socket
from html import unescape
from urllib.parse import urljoin, urlsplit

logger = logging.getLogger("siberia.link_preview")

_MAX_BYTES = 512 * 1024
_MAX_REDIRECTS = 3
_TIMEOUT = 8.0
_CACHE_TTL = 24 * 3600

_URL_RE = re.compile(r"https?://[^\s<>\"']+", re.IGNORECASE)


def extract_first_url(text: str | None) -> str | None:
    if not text:
        return None
    m = _URL_RE.search(text)
    if not m:
        return None
    # Обрезаем хвостовую пунктуацию («смотри https://x.com/a.» → без точки)
    url = m.group(0).rstrip(".,;:!?)»”'\"")
    return url if len(url) <= 2048 else None


def _is_public_host(host: str) -> bool:
    """Резолвим хост и требуем, чтобы ВСЕ адреса были публичными (анти-SSRF)."""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    if not infos:
        return False
    for info in infos:
        ip_str = info[4][0]
        try:
            ip = ipaddress.ip_address(ip_str)
        except ValueError:
            return False
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_multicast or ip.is_reserved or ip.is_unspecified):
            return False
    return True


def _check_url_allowed(url: str) -> tuple[bool, str]:
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        return False, "scheme"
    if not parts.hostname:
        return False, "no host"
    if not _is_public_host(parts.hostname):
        return False, f"private host {parts.hostname}"
    return True, ""


_META_RE = re.compile(
    r"<meta\s[^>]*?(?:property|name)\s*=\s*[\"'](og:[a-z_:]+|twitter:[a-z_:]+|description)[\"'][^>]*?>",
    re.IGNORECASE | re.DOTALL,
)
_CONTENT_RE = re.compile(r"content\s*=\s*([\"'])(.*?)\1", re.IGNORECASE | re.DOTALL)
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def parse_og(html: str, base_url: str) -> dict | None:
    """Достаёт og:title/description/image/site_name (+ twitter- и <title>-фолбэки)."""
    tags: dict[str, str] = {}
    for m in _META_RE.finditer(html):
        key = m.group(1).lower()
        cm = _CONTENT_RE.search(m.group(0))
        if cm and key not in tags:
            tags[key] = unescape(cm.group(2)).strip()

    title = tags.get("og:title") or tags.get("twitter:title")
    if not title:
        tm = _TITLE_RE.search(html)
        if tm:
            title = unescape(tm.group(1)).strip()
    description = tags.get("og:description") or tags.get("twitter:description") or tags.get("description")
    image = tags.get("og:image") or tags.get("twitter:image")
    site_name = tags.get("og:site_name")

    if not title and not description:
        return None

    if image:
        image = urljoin(base_url, image)
        ok, _ = _check_url_allowed(image)
        if not ok:
            image = None

    def _clip(s: str | None, n: int) -> str | None:
        if s is None:
            return None
        s = re.sub(r"\s+", " ", s).strip()
        return s[:n] if s else None

    return {
        "url": base_url,
        "title": _clip(title, 200),
        "description": _clip(description, 300),
        "image_url": image,
        "site_name": _clip(site_name, 100),
    }


async def fetch_og_preview(url: str) -> dict | None:
    """Скачивает страницу (SSRF-safe, ручные редиректы, лимит байт) и парсит OG."""
    import httpx

    current = url
    for _ in range(_MAX_REDIRECTS + 1):
        ok, reason = _check_url_allowed(current)
        if not ok:
            logger.info("link_preview blocked (%s): %s", reason, current[:120])
            return None

        try:
            async with httpx.AsyncClient(
                timeout=_TIMEOUT, follow_redirects=False,
                headers={"User-Agent": "SiberiaBot/1.0 (+link preview)"},
            ) as client:
                async with client.stream("GET", current) as resp:
                    if resp.status_code in (301, 302, 303, 307, 308):
                        loc = resp.headers.get("location")
                        if not loc:
                            return None
                        current = urljoin(current, loc)
                        continue
                    if resp.status_code != 200:
                        return None
                    ctype = resp.headers.get("content-type", "")
                    if "text/html" not in ctype:
                        return None
                    chunks: list[bytes] = []
                    total = 0
                    async for chunk in resp.aiter_bytes():
                        total += len(chunk)
                        chunks.append(chunk)
                        if total >= _MAX_BYTES:
                            break
                    html = b"".join(chunks).decode(resp.encoding or "utf-8", errors="replace")
                    return parse_og(html, current)
        except Exception as exc:  # noqa: BLE001
            logger.info("link_preview fetch failed %s: %s", current[:120], exc)
            return None
    return None


async def build_preview_cached(url: str) -> dict | None:
    """fetch_og_preview с Redis-кешем по URL (и негативным кешем)."""
    from utils.redis import redis_client

    cache_key = f"link_preview:{url}"
    try:
        cached = await redis_client.get(cache_key)
        if cached is not None:
            return json.loads(cached) if cached != "null" else None
    except Exception:  # noqa: BLE001
        pass

    preview = await fetch_og_preview(url)
    try:
        await redis_client.set(cache_key, json.dumps(preview) if preview else "null", ex=_CACHE_TTL)
    except Exception:  # noqa: BLE001
        pass
    return preview
