"""Stories: создание, лента для друзей, просмотры, удаление, срок жизни."""
import uuid

from sqlalchemy import text


async def _make_media(owner_id: int, media_type: str = "image") -> str:
    """Сажаем Media напрямую (S3 в тестах нет; presigned_url уйдёт в None)."""
    from db import async_session_maker
    from models.media import Media, MediaType

    mid = uuid.uuid4()
    async with async_session_maker() as db:
        db.add(Media(
            id=mid, uploader_id=owner_id, type=MediaType(media_type),
            mime_type="image/jpeg", size_bytes=1000, s3_key=f"test/{mid}.jpg",
        ))
        await db.commit()
    return str(mid)


async def _befriend(client, a, b):
    r = await client.post(f"/friends/add/{b.id}", headers=a.headers)
    assert r.status_code == 200, r.text
    reqs = (await client.get("/friends/requests", headers=b.headers)).json()
    rid = next(x["request_id"] for x in reqs if x["user"]["id"] == a.id)
    r = await client.post(f"/friends/accept/{rid}", headers=b.headers)
    assert r.status_code == 200, r.text


async def test_story_feed_visible_to_friends_only(client, register_user):
    author = await register_user("st_auth")
    friend = await register_user("st_frnd")
    stranger = await register_user("st_strg")
    await _befriend(client, author, friend)

    media_id = await _make_media(author.id)
    r = await client.post(
        "/stories", json={"media_id": media_id, "caption": "закат"}, headers=author.headers
    )
    assert r.status_code == 200, r.text
    story_id = r.json()["id"]

    # Друг видит группу автора, сторис не просмотрена
    feed = (await client.get("/stories/feed", headers=friend.headers)).json()
    group = next((g for g in feed if g["user"]["id"] == author.id), None)
    assert group is not None
    assert group["all_viewed"] is False
    assert group["stories"][0]["caption"] == "закат"
    assert group["stories"][0]["views_count"] is None  # не автор

    # Незнакомец — не видит
    feed = (await client.get("/stories/feed", headers=stranger.headers)).json()
    assert all(g["user"]["id"] != author.id for g in feed)

    # И не может отметить просмотр
    r = await client.post(f"/stories/{story_id}/view", headers=stranger.headers)
    assert r.status_code == 403


async def test_view_marks_and_author_sees_viewers(client, register_user):
    author = await register_user("vw_auth")
    friend = await register_user("vw_frnd")
    await _befriend(client, author, friend)
    media_id = await _make_media(author.id)
    story_id = (await client.post(
        "/stories", json={"media_id": media_id}, headers=author.headers
    )).json()["id"]

    # Просмотр (идемпотентный)
    assert (await client.post(f"/stories/{story_id}/view", headers=friend.headers)).status_code == 200
    assert (await client.post(f"/stories/{story_id}/view", headers=friend.headers)).status_code == 200

    # У друга сторис теперь viewed, группа all_viewed
    feed = (await client.get("/stories/feed", headers=friend.headers)).json()
    group = next(g for g in feed if g["user"]["id"] == author.id)
    assert group["all_viewed"] is True

    # Автор видит счётчик и список посмотревших (email скрыт)
    feed = (await client.get("/stories/feed", headers=author.headers)).json()
    own = next(g for g in feed if g["user"]["id"] == author.id)
    assert own["stories"][0]["views_count"] == 1

    viewers = (await client.get(f"/stories/{story_id}/views", headers=author.headers)).json()
    assert [v["id"] for v in viewers] == [friend.id]
    assert viewers[0]["email"] is None

    # Друг список посмотревших не видит
    r = await client.get(f"/stories/{story_id}/views", headers=friend.headers)
    assert r.status_code == 403


async def test_media_ownership_and_type_validated(client, register_user):
    author = await register_user("mv_auth")
    other = await register_user("mv_other")

    foreign_media = await _make_media(other.id)
    r = await client.post("/stories", json={"media_id": foreign_media}, headers=author.headers)
    assert r.status_code == 403

    voice = await _make_media(author.id, media_type="voice")
    r = await client.post("/stories", json={"media_id": voice}, headers=author.headers)
    assert r.status_code == 400


async def test_delete_and_expiry(client, register_user):
    author = await register_user("ex_auth")
    friend = await register_user("ex_frnd")
    await _befriend(client, author, friend)

    m1 = await _make_media(author.id)
    m2 = await _make_media(author.id)
    s1 = (await client.post("/stories", json={"media_id": m1}, headers=author.headers)).json()["id"]
    s2 = (await client.post("/stories", json={"media_id": m2}, headers=author.headers)).json()["id"]

    # Чужую сторис удалить нельзя
    assert (await client.delete(f"/stories/{s1}", headers=friend.headers)).status_code == 403
    # Свою — можно
    assert (await client.delete(f"/stories/{s1}", headers=author.headers)).status_code == 200

    # Протухшая сторис уходит из ленты и не отмечается просмотром
    from db import async_session_maker
    async with async_session_maker() as db:
        await db.execute(
            text("UPDATE stories SET expires_at = now() - interval '1 hour' WHERE id = :id"),
            {"id": s2},
        )
        await db.commit()

    feed = (await client.get("/stories/feed", headers=friend.headers)).json()
    assert all(g["user"]["id"] != author.id for g in feed)
    assert (await client.post(f"/stories/{s2}/view", headers=friend.headers)).status_code == 404

    # А воркер её физически подчищает
    import worker as worker_mod
    await worker_mod.cleanup_expired_stories({})
    async with async_session_maker() as db:
        left = (await db.execute(text("SELECT count(*) FROM stories WHERE id = :id"), {"id": s2})).scalar()
    assert left == 0
