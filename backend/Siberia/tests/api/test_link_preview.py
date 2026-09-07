"""Link preview: извлечение URL, OG-парсер, SSRF-защита, доставка воркером."""
import worker as worker_mod
from services.link_preview import _check_url_allowed, extract_first_url, parse_og


# ── Юниты ────────────────────────────────────────────────────────────────────

def test_extract_first_url():
    assert extract_first_url("глянь https://example.com/a?x=1, потом") == "https://example.com/a?x=1"
    assert extract_first_url("ссылка (https://a.io/path).") == "https://a.io/path"
    assert extract_first_url("без ссылок тут") is None
    assert extract_first_url(None) is None
    assert extract_first_url("ftp://old.school/file") is None


def test_parse_og_basic_and_fallbacks():
    html = """
    <html><head>
      <title>Fallback Title</title>
      <meta property="og:title" content="Настоящий заголовок"/>
      <meta property="og:description" content="Описание &amp; детали">
      <meta property="og:image" content="/img/cover.png">
      <meta property="og:site_name" content="Example">
    </head></html>
    """
    p = parse_og(html, "https://example.com/page")
    assert p["title"] == "Настоящий заголовок"
    assert p["description"] == "Описание & детали"
    assert p["image_url"] == "https://example.com/img/cover.png"
    assert p["site_name"] == "Example"

    # Без OG — падаем на <title>
    p2 = parse_og("<html><head><title>Просто тайтл</title></head></html>", "https://x.io")
    assert p2["title"] == "Просто тайтл"

    # Совсем пусто → None
    assert parse_og("<html><body>hi</body></html>", "https://x.io") is None


def test_ssrf_guard_blocks_private_hosts():
    for bad in (
        "http://127.0.0.1/admin",
        "http://localhost:8000/",
        "http://192.168.1.1/router",
        "http://10.0.0.5/internal",
        "http://[::1]/",
        "file:///etc/passwd",
        "gopher://x",
    ):
        ok, _ = _check_url_allowed(bad)
        assert not ok, f"SSRF guard must block {bad}"


# ── Интеграция: воркер пишет превью и оно видно в истории ────────────────────

async def test_worker_attaches_preview_to_message(client, register_user, monkeypatch):
    a = await register_user("lp_a")
    b = await register_user("lp_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "смотри https://news.example.org/story"},
        headers=a.headers,
    )
    msg_id = r.json()["message"]["id"]
    assert r.json()["message"]["link_preview"] is None  # ещё не выкачано

    fake = {
        "url": "https://news.example.org/story",
        "title": "Большая новость",
        "description": "Подробности внутри",
        "image_url": None,
        "site_name": "News",
    }

    async def fake_fetch(url):
        assert url == "https://news.example.org/story"
        return fake

    import services.link_preview as lp
    monkeypatch.setattr(lp, "fetch_og_preview", fake_fetch)

    await worker_mod.fetch_link_preview({}, msg_id, "https://news.example.org/story")

    r = await client.get(f"/chats/{chat_id}/messages", headers=b.headers)
    msg = next(m for m in r.json() if m["id"] == msg_id)
    assert msg["link_preview"] == fake


async def test_worker_skips_dead_or_blocked_urls(client, register_user, monkeypatch):
    a = await register_user("lpx_a")
    b = await register_user("lpx_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]
    msg_id = (await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "http://127.0.0.1/secret"},
        headers=a.headers,
    )).json()["message"]["id"]

    # Реальный fetch: SSRF-guard отсекает приватный хост ещё до сети
    await worker_mod.fetch_link_preview({}, msg_id, "http://127.0.0.1/secret")

    r = await client.get(f"/chats/{chat_id}/messages", headers=a.headers)
    msg = next(m for m in r.json() if m["id"] == msg_id)
    assert msg["link_preview"] is None
