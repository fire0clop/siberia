"""Архив чатов (per-user) и пользовательские папки."""


async def _dm(client, a, b):
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    return r.json()["id"]


async def test_archive_is_per_user_and_reversible(client, register_user):
    a = await register_user("ar_a")
    b = await register_user("ar_b")
    chat_id = await _dm(client, a, b)

    r = await client.post(f"/chats/{chat_id}/archive", headers=a.headers)
    assert r.status_code == 200, r.text

    # У A чат помечен архивным
    chat_a = next(c for c in (await client.get("/chats", headers=a.headers)).json() if c["id"] == chat_id)
    assert chat_a["is_archived"] is True

    # У B — нет (архив per-user)
    chat_b = next(c for c in (await client.get("/chats", headers=b.headers)).json() if c["id"] == chat_id)
    assert chat_b["is_archived"] is False

    # Доставка в архивный чат работает
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "в архив"}, headers=b.headers)
    assert r.status_code == 200

    # Разархив
    await client.delete(f"/chats/{chat_id}/archive", headers=a.headers)
    chat_a = next(c for c in (await client.get("/chats", headers=a.headers)).json() if c["id"] == chat_id)
    assert chat_a["is_archived"] is False


async def test_archive_requires_membership(client, register_user):
    a = await register_user("am_a")
    b = await register_user("am_b")
    outsider = await register_user("am_o")
    chat_id = await _dm(client, a, b)

    r = await client.post(f"/chats/{chat_id}/archive", headers=outsider.headers)
    assert r.status_code == 403


async def test_folders_crud_and_membership_guard(client, register_user):
    a = await register_user("fd_a")
    b = await register_user("fd_b")
    c = await register_user("fd_c")
    chat_ab = await _dm(client, a, b)
    chat_ac = await _dm(client, a, c)
    foreign_chat = await _dm(client, b, c)  # A там не состоит

    # Создание
    r = await client.post("/folders", json={"name": "Работа"}, headers=a.headers)
    assert r.status_code == 200, r.text
    folder_id = r.json()["id"]
    assert r.json()["chat_ids"] == []

    # Наполнение
    r = await client.put(
        f"/folders/{folder_id}/chats", json={"chat_ids": [chat_ab, chat_ac]}, headers=a.headers
    )
    assert r.status_code == 200, r.text
    assert sorted(r.json()["chat_ids"]) == sorted([chat_ab, chat_ac])

    # Чужой чат в папку не положить
    r = await client.put(
        f"/folders/{folder_id}/chats", json={"chat_ids": [foreign_chat]}, headers=a.headers
    )
    assert r.status_code == 403

    # Листинг
    r = await client.get("/folders", headers=a.headers)
    folders = r.json()
    assert len(folders) == 1
    assert folders[0]["name"] == "Работа"
    assert sorted(folders[0]["chat_ids"]) == sorted([chat_ab, chat_ac])

    # Переименование
    r = await client.patch(f"/folders/{folder_id}", json={"name": "Дела"}, headers=a.headers)
    assert r.json()["name"] == "Дела"

    # Чужую папку не видно и не трогать
    r = await client.get("/folders", headers=b.headers)
    assert r.json() == []
    r = await client.patch(f"/folders/{folder_id}", json={"name": "хак"}, headers=b.headers)
    assert r.status_code == 404

    # Удаление
    r = await client.delete(f"/folders/{folder_id}", headers=a.headers)
    assert r.status_code == 200
    assert (await client.get("/folders", headers=a.headers)).json() == []


async def test_folder_replace_semantics(client, register_user):
    a = await register_user("fr_a")
    b = await register_user("fr_b")
    c = await register_user("fr_c")
    chat_ab = await _dm(client, a, b)
    chat_ac = await _dm(client, a, c)

    folder_id = (await client.post("/folders", json={"name": "F"}, headers=a.headers)).json()["id"]
    await client.put(f"/folders/{folder_id}/chats", json={"chat_ids": [chat_ab]}, headers=a.headers)
    # PUT — полная замена
    r = await client.put(f"/folders/{folder_id}/chats", json={"chat_ids": [chat_ac]}, headers=a.headers)
    assert r.json()["chat_ids"] == [chat_ac]
    # Очистка пустым списком
    r = await client.put(f"/folders/{folder_id}/chats", json={"chat_ids": []}, headers=a.headers)
    assert r.json()["chat_ids"] == []
