"""Text entities (markdown-разметка): хранение, валидация, edit, forward."""


async def _dm(client, a, b):
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    return r.json()["id"]


async def test_entities_roundtrip(client, register_user):
    a = await register_user("ent_a")
    b = await register_user("ent_b")
    chat_id = await _dm(client, a, b)

    entities = [
        {"type": "bold", "offset": 0, "length": 6},
        {"type": "spoiler", "offset": 7, "length": 6},
    ]
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "Жирный спойлер", "entities": entities},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    assert msg["entities"] == entities

    # И в истории сообщений
    r = await client.get(f"/chats/{chat_id}/messages", headers=b.headers)
    fetched = next(m for m in r.json() if m["id"] == msg["id"])
    assert fetched["entities"] == entities


async def test_entities_validated_against_text(client, register_user):
    a = await register_user("ev_a")
    b = await register_user("ev_b")
    chat_id = await _dm(client, a, b)

    # За пределами текста → 400
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "короткий", "entities": [{"type": "bold", "offset": 5, "length": 100}]},
        headers=a.headers,
    )
    assert r.status_code == 400

    # Неизвестный тип → 422 (pydantic pattern)
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "текст", "entities": [{"type": "blink", "offset": 0, "length": 5}]},
        headers=a.headers,
    )
    assert r.status_code in (400, 422)


async def test_entities_utf16_offsets_with_emoji(client, register_user):
    """Эмодзи занимает 2 UTF-16 юнита — границы считаются в них."""
    a = await register_user("emj_a")
    b = await register_user("emj_b")
    chat_id = await _dm(client, a, b)

    text = "🔥 да"  # UTF-16: 🔥=2, пробел=1, "да"=2 → всего 5 юнитов
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": text, "entities": [{"type": "bold", "offset": 3, "length": 2}]},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text

    # offset+length == 6 > 5 юнитов → 400
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": text, "entities": [{"type": "bold", "offset": 4, "length": 2}]},
        headers=a.headers,
    )
    assert r.status_code == 400


async def test_edit_replaces_entities(client, register_user):
    a = await register_user("ee_a")
    b = await register_user("ee_b")
    chat_id = await _dm(client, a, b)
    msg_id = (await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "старый", "entities": [{"type": "bold", "offset": 0, "length": 6}]},
        headers=a.headers,
    )).json()["message"]["id"]

    r = await client.patch(
        f"/messages/{msg_id}",
        json={"content": "новый курсив", "entities": [{"type": "italic", "offset": 6, "length": 6}]},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["entities"] == [{"type": "italic", "offset": 6, "length": 6}]

    # Edit без entities очищает разметку
    r = await client.patch(f"/messages/{msg_id}", json={"content": "чистый"}, headers=a.headers)
    assert r.json()["entities"] is None


async def test_forward_carries_entities(client, register_user):
    a = await register_user("fw_a")
    b = await register_user("fw_b")
    c = await register_user("fw_c")
    chat_ab = await _dm(client, a, b)
    chat_ac = await _dm(client, a, c)

    src = (await client.post(
        f"/chats/{chat_ab}/messages",
        json={"content": "жирная правда", "entities": [{"type": "bold", "offset": 0, "length": 6}]},
        headers=a.headers,
    )).json()["message"]["id"]

    r = await client.post(
        f"/chats/{chat_ac}/messages",
        json={"forward_message_id": src},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text
    fwd = r.json()["message"]
    assert fwd["entities"] == [{"type": "bold", "offset": 0, "length": 6}]
