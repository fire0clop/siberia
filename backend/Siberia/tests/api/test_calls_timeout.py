"""Зависший ringing-звонок не должен вечно блокировать участников (H-7)."""
from sqlalchemy import text


async def _call(client, u, callee_id):
    return await client.post(
        "/calls", json={"callee_id": callee_id, "type": "audio"}, headers=u.headers
    )


async def test_stale_ringing_call_no_longer_blocks(client, register_user):
    a = await register_user("call_a")
    b = await register_user("call_b")

    r = await _call(client, a, b.id)
    assert r.status_code == 200, r.text
    stale_id = r.json()["id"]

    # Живой ringing честно блокирует повторный вызов
    r = await _call(client, a, b.id)
    assert r.status_code == 409

    # «Упавшее приложение»: состариваем звонок за пределы RING_TIMEOUT_SECONDS
    from db import async_session_maker
    async with async_session_maker() as db:
        await db.execute(
            text("UPDATE calls SET started_at = started_at - interval '180 seconds' WHERE id = :id"),
            {"id": stale_id},
        )
        await db.commit()

    # Теперь initiate сам гасит протухший и создаёт новый звонок
    r = await _call(client, a, b.id)
    assert r.status_code == 200, f"stale ringing still blocks: {r.text}"
    new_id = r.json()["id"]
    assert new_id != stale_id

    # Протухший помечен missed
    r = await client.get("/calls/history", headers=a.headers)
    by_id = {c["id"]: c for c in r.json()}
    assert by_id[stale_id]["status"] == "missed"
    assert by_id[new_id]["status"] == "ringing"
    # Бонус: история не светит email собеседника (C-4)
    assert by_id[new_id]["callee"]["email"] is None


async def test_caller_ending_ringing_call_records_cancelled(client, register_user):
    a = await register_user("end_a")
    b = await register_user("end_b")
    call_id = (await _call(client, a, b.id)).json()["id"]

    r = await client.post(f"/calls/{call_id}/end", headers=a.headers)
    assert r.status_code == 200
    assert r.json()["status"] == "cancelled"
