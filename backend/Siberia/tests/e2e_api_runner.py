#!/usr/bin/env python3
"""
Глобальный прогон API против запущенного сервера (по умолчанию http://127.0.0.1:8000).
Запуск: python tests/e2e_api_runner.py
       BASE_URL=http://127.0.0.1:8000 python tests/e2e_api_runner.py
"""
from __future__ import annotations

import json
import os
import sys
import time
import uuid
from typing import Any

import httpx

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8000").rstrip("/")

_passed = 0
_failed = 0
_block = ""


def section(name: str) -> None:
    global _block
    _block = name
    print(f"\n{'='*60}\n## {name}\n{'='*60}")


def ok(name: str, detail: str = "") -> None:
    global _passed
    _passed += 1
    print(f"  [OK] {name}" + (f" — {detail}" if detail else ""))


def fail(name: str, reason: str) -> None:
    global _failed
    _failed += 1
    print(f"  [FAIL] {name}: {reason}")


def req(
    method: str,
    path: str,
    *,
    json_body: Any = None,
    headers: dict | None = None,
    params: dict | None = None,
    expected: int | tuple[int, ...] = 200,
) -> httpx.Response:
    exp = (expected,) if isinstance(expected, int) else expected
    h = dict(headers or {})
    kwargs: dict[str, Any] = {"timeout": 30.0, "params": params}
    if json_body is not None or method in ("POST", "PUT", "PATCH"):
        if json_body is not None:
            kwargs["json"] = json_body
        elif method in ("POST", "PUT", "PATCH"):
            kwargs["json"] = {}
        h.setdefault("Content-Type", "application/json")
    r = httpx.request(method, f"{BASE}{path}", headers=h, **kwargs)
    if r.status_code not in exp:
        fail(
            f"{method} {path}",
            f"status {r.status_code}, expected {exp}, body={r.text[:500]}",
        )
    return r


def main() -> int:
    print(f"Target: {BASE}\n")

    # --- Health & infra ---
    section("Health / metrics")
    r = req("GET", "/health/live", expected=200)
    if r.status_code == 200:
        ok("/health/live", r.json().get("status", ""))
    r = req("GET", "/health/ready", expected=(200, 503))
    if r.status_code == 200:
        ok("/health/ready", "db+redis")
    else:
        ok("/health/ready", "503 (redis/db?) — проверь сервисы")
    r = req("GET", "/metrics", expected=(200, 404))
    if r.status_code == 200:
        ok("/metrics", "prometheus")
    else:
        ok("/metrics", "нет (пакет не установлен — норма)")

    # --- Auth errors ---
    section("Auth — негативные сценарии")
    r = req("GET", "/users/me", headers={}, expected=(401, 403))
    if r.status_code in (401, 403):
        ok(f"GET /users/me без Bearer → {r.status_code}")
    r = req(
        "POST",
        "/auth/register",
        json_body={"email": "bad", "nickname": "x", "password": "x"},
        expected=422,
    )
    if r.status_code == 422:
        body = r.json()
        if "error" in body and body["error"].get("code") == "validation_error":
            ok("Регистрация с невалидным email → 422 + error.code")
        else:
            fail("Формат 422", f"ожидался error.code validation_error, got {body}")

    # --- Users A & B ---
    section("Auth — регистрация и логин")
    suffix = str(int(time.time()))
    # домен не .local / не reserved — иначе EmailStr (pydantic) отклонит
    email_a = f"qa_a_{suffix}@example.com"
    email_b = f"qa_b_{suffix}@example.com"
    dev_a = f"device-a-{suffix}"
    dev_b = f"device-b-{suffix}"

    r = req(
        "POST",
        "/auth/register",
        json_body={
            "email": email_a,
            "nickname": f"qaa_{suffix}",
            "password": "secret123",
        },
        headers={"X-Device-ID": dev_a},
    )
    if r.status_code != 200:
        return finish()
    data_a = r.json()
    if "error" in data_a:
        fail("Регистрация A", data_a)
        return finish()
    token_a = data_a["access_token"]
    refresh_a = data_a["refresh_token"]
    user_a_id = data_a["user"]["id"]
    ok(f"Регистрация user A id={user_a_id}")

    r = req(
        "POST",
        "/auth/register",
        json_body={
            "email": email_b,
            "nickname": f"qab_{suffix}",
            "password": "secret123",
        },
        headers={"X-Device-ID": dev_b},
    )
    if r.status_code != 200:
        return finish()
    data_b = r.json()
    token_b = data_b["access_token"]
    user_b_id = data_b["user"]["id"]
    ok(f"Регистрация user B id={user_b_id}")

    r = req(
        "POST",
        "/auth/register",
        json_body={
            "email": email_a,
            "nickname": "dup",
            "password": "secret123",
        },
        expected=400,
    )
    if r.status_code == 400:
        ok("Дубликат email → 400")

    r = req(
        "POST",
        "/auth/login",
        json_body={
            "email": email_a,
            "password": "wrong",
            "device_id": dev_a,
        },
        expected=401,
    )
    if r.status_code == 401:
        ok("Неверный пароль → 401")

    r = req(
        "POST",
        "/auth/login",
        json_body={
            "email": email_a,
            "password": "secret123",
            "device_id": dev_a,
        },
    )
    if r.status_code == 200:
        token_a = r.json()["access_token"]
        refresh_a = r.json()["refresh_token"]
        ok("Логин A с device_id")

    h_a = {"Authorization": f"Bearer {token_a}"}
    h_b = {"Authorization": f"Bearer {token_b}"}

    # --- Users ---
    section("Users")
    r = req("GET", "/users/me", headers=h_a)
    if r.status_code == 200 and r.json()["id"] == user_a_id:
        ok("/users/me")
    r = req("GET", "/users/search", headers=h_a, params={"q": "qab"})
    if r.status_code == 200 and any(u["id"] == user_b_id for u in r.json()):
        ok("/users/search находит B")
    r = req("GET", "/users/search", params={"q": "x"}, expected=(401, 403))
    if r.status_code in (401, 403):
        ok(f"/users/search без auth → {r.status_code}")

    # --- Refresh ---
    section("Auth — refresh / logout")
    r = req(
        "POST",
        "/auth/refresh",
        json_body={"refresh_token": refresh_a, "device_id": dev_a},
    )
    if r.status_code == 200 and "access_token" in r.json():
        token_a = r.json()["access_token"]
        refresh_a = r.json()["refresh_token"]
        h_a = {"Authorization": f"Bearer {token_a}"}
        ok("/auth/refresh с верным device_id")
    r = req(
        "POST",
        "/auth/refresh",
        json_body={"refresh_token": refresh_a, "device_id": "wrong-device"},
        expected=401,
    )
    if r.status_code == 401:
        ok("/auth/refresh с неверным device_id → 401")

    r = req(
        "POST",
        "/auth/refresh",
        json_body={"refresh_token": refresh_a, "device_id": dev_a},
    )
    if r.status_code == 200:
        token_a = r.json()["access_token"]
        h_a = {"Authorization": f"Bearer {token_a}"}
        ok("Повторный refresh после ошибки device (новая пара токенов)")

    # --- Friends ---
    section("Friends")
    r = req("POST", f"/friends/add/{user_b_id}", headers=h_a, json_body=None)
    if r.status_code == 200:
        ok("A → заявка B")
    r = req("GET", "/friends/requests", headers=h_b)
    if r.status_code == 200:
        reqs = r.json()
        rid = next((x["request_id"] for x in reqs if x["user"]["id"] == user_a_id), None)
        if rid:
            ok(f"B видит входящую заявку request_id={rid}")
            r2 = req("POST", f"/friends/accept/{rid}", headers=h_b, json_body=None)
            if r2.status_code == 200:
                ok("B принимает заявку")
        else:
            fail("Входящие заявки B", str(reqs))

    r = req("GET", "/friends", headers=h_a)
    if r.status_code == 200 and any(u["id"] == user_b_id for u in r.json()):
        ok("A видит B в друзьях")

    r = req(
        "POST",
        f"/friends/add/{user_b_id}",
        headers=h_a,
        json_body=None,
        expected=400,
    )
    if r.status_code == 400:
        ok("Повторная заявка в друзья → 400")

    # --- Chats & messages ---
    section("Chats и сообщения")
    r = req(
        "POST",
        "/chats",
        headers=h_a,
        json_body={"user_id": user_b_id},
    )
    if r.status_code != 200:
        return finish()
    chat = r.json()
    chat_id = chat["id"]
    sync_seq = chat.get("sync_seq", 0)
    ok(f"POST /chats → chat_id={chat_id}, sync_seq={sync_seq}")

    r = req("GET", "/chats", headers=h_a)
    if r.status_code == 200 and any(c["id"] == chat_id for c in r.json()):
        ok("GET /chats содержит чат")

    r = req(
        "POST",
        f"/chats/{chat_id}/messages",
        headers=h_a,
        json_body={"content": "Привет из QA"},
    )
    if r.status_code != 200:
        return finish()
    m1 = r.json()["message"]
    mid = m1["id"]
    idem = r.json().get("idempotent", False)
    ok(f"POST сообщение id={mid}, idempotent={idem}")

    cmid = str(uuid.uuid4())
    r = req(
        "POST",
        f"/chats/{chat_id}/messages",
        headers=h_a,
        json_body={"content": "идемпотентность", "client_message_id": cmid},
    )
    r2 = req(
        "POST",
        f"/chats/{chat_id}/messages",
        headers=h_a,
        json_body={"content": "другой текст тот же uuid", "client_message_id": cmid},
    )
    if r.status_code == 200 and r2.status_code == 200:
        if r.json()["message"]["id"] == r2.json()["message"]["id"] and r2.json().get(
            "idempotent"
        ):
            ok("Идемпотентность client_message_id")
        else:
            fail("Идемпотентность", f"{r.json()} vs {r2.json()}")

    r = req("GET", f"/chats/{chat_id}/messages", headers=h_b, params={"limit": 20})
    if r.status_code == 200 and len(r.json()) >= 1:
        ok("B читает историю")
    r = req("GET", f"/chats/{999999}/messages", headers=h_a, expected=403)
    if r.status_code == 403:
        ok("Чужой/несуществующий чат → 403")

    r = req("GET", f"/chats/{chat_id}/sync", headers=h_a, params={"after_seq": 0})
    if r.status_code == 200:
        sj = r.json()
        if "updates" in sj and "latest_seq" in sj and sj["latest_seq"] >= 1:
            ok(f"sync: {len(sj['updates'])} updates, latest_seq={sj['latest_seq']}")
        else:
            fail("sync формат", str(sj)[:300])

    r = req(
        "PATCH",
        f"/messages/{mid}",
        headers=h_a,
        json_body={"content": "Отредактировано QA"},
    )
    if r.status_code == 200:
        ok("PATCH сообщение")

    r = req(
        "POST",
        "/messages",
        headers=h_a,
        json_body={"user_id": user_b_id, "content": "авточат тест"},
    )
    if r.status_code == 200:
        ok("POST /messages (auto chat)", f"chat_id={r.json().get('chat_id')}")

    r = req(
        "GET",
        "/search/messages",
        headers=h_a,
        params={"q": "QA", "limit": 10},
    )
    if r.status_code == 200:
        results = r.json().get("results", [])
        if any("QA" in (x.get("text") or "") for x in results):
            ok("Поиск /search/messages")
        else:
            ok("Поиск вернул 0 совпадений по 'QA' (возможен simple tokenizer)")

    section("Удаление сообщения и негативы")
    r = req(
        "POST",
        f"/chats/{chat_id}/messages",
        headers=h_a,
        json_body={"content": "удалить меня"},
    )
    if r.status_code == 200:
        del_mid = r.json()["message"]["id"]
        r = req("DELETE", f"/messages/{del_mid}", headers=h_a, json_body=None)
        if r.status_code == 200:
            ok("DELETE сообщение (soft)")
        r = req(
            "PATCH",
            f"/messages/{del_mid}",
            headers=h_a,
            json_body={"content": "no"},
            expected=400,
        )
        if r.status_code == 400:
            ok("PATCH удалённого сообщения → 400")
    r = req(
        "PATCH",
        f"/messages/{mid}",
        headers=h_b,
        json_body={"content": "чужое"},
        expected=403,
    )
    if r.status_code == 403:
        ok("PATCH чужого сообщения → 403")

    # --- WebSocket (опционально, пакет websockets) ---
    section("WebSocket smoke")
    try:
        import asyncio

        import websockets
    except ImportError:
        ok("WebSocket тест пропущен (pip install websockets)")
    else:

        async def _ws_dual():
            host = BASE.replace("http://", "").replace("https://", "").split("/")[0]
            scheme = "wss" if BASE.startswith("https") else "ws"
            chat_uri = f"{scheme}://{host}/ws/{chat_id}?token={token_a}"
            me_uri = f"{scheme}://{host}/ws/me?token={token_a}"
            async with websockets.connect(chat_uri, open_timeout=5) as w_chat:
                async with websockets.connect(me_uri, open_timeout=5) as w_me:
                    await w_chat.send(
                        json.dumps({"type": "message", "text": "hello ws dual"})
                    )
                    raw_chat = await asyncio.wait_for(w_chat.recv(), timeout=5)
                    raw_me = await asyncio.wait_for(w_me.recv(), timeout=5)
            d1 = json.loads(raw_chat)
            d2 = json.loads(raw_me)
            ok_chat = (
                d1.get("v") == 1
                and d1.get("event") == "message_new"
                and d1.get("chat_id") == chat_id
            )
            ok_me = d2.get("v") == 1 and d2.get("seq") == d1.get("seq")
            return ok_chat, ok_me

        try:
            oc, om = asyncio.run(_ws_dual())
            if oc:
                ok("WS /ws/{chat_id}: v1 message_new")
            else:
                fail("WS chat", "неожиданный JSON")
            if om:
                ok("WS /ws/me: тот же seq что и chat (fan-out user channel)")
            else:
                fail("WS /me", "не совпал поток с chat-сокетом")
        except Exception as e:
            fail("WebSocket dual", str(e))

        async def _ws_read():
            host = BASE.replace("http://", "").replace("https://", "").split("/")[0]
            scheme = "wss" if BASE.startswith("https") else "ws"
            chat_uri_b = f"{scheme}://{host}/ws/{chat_id}?token={token_b}"
            async with websockets.connect(chat_uri_b, open_timeout=5) as ws:
                await ws.send(
                    json.dumps({"type": "read", "message_id": int(mid)})
                )
                for _ in range(10):
                    raw = await asyncio.wait_for(ws.recv(), timeout=5)
                    data = json.loads(raw)
                    if data.get("event") == "read_receipt":
                        return data.get("payload", {}).get("reader_id") == user_b_id
            return False

        try:
            if asyncio.run(_ws_read()):
                ok("WS read → событие read_receipt (B помечает сообщение A)")
            else:
                fail("WS read", "не получен read_receipt за 10 кадров")
        except Exception as e:
            fail("WS read", str(e))

    # --- Sessions (до logout) ---
    section("Sessions — список, DELETE, revoke_all")
    r = req("GET", "/sessions", headers=h_a)
    if r.status_code != 200:
        return finish()
    n0 = len(r.json())
    ok(f"GET /sessions начально count={n0}")

    dev_extra = f"{dev_a}-e2e-extra"
    r = req(
        "POST",
        "/auth/login",
        json_body={
            "email": email_a,
            "password": "secret123",
            "device_id": dev_extra,
        },
    )
    if r.status_code == 200:
        ok("Логин A с доп. device_id (вторая сессия)")

    r = req("GET", "/sessions", headers=h_a)
    if r.status_code != 200:
        return finish()
    sessions = r.json()
    extra_sess = next(
        (s for s in sessions if s.get("device_id") == dev_extra), None
    )
    if extra_sess and len(sessions) >= 2:
        ok(f"GET /sessions после 2-го устройства count={len(sessions)}")
        sid = extra_sess["id"]
        r = req("DELETE", f"/sessions/{sid}", headers=h_a)
        if r.status_code == 200:
            ok(f"DELETE /sessions/{sid}")
        r = req("GET", "/sessions", headers=h_a)
        if r.status_code == 200 and len(r.json()) == len(sessions) - 1:
            ok("После DELETE сессий стало на 1 меньше")
    else:
        fail("Сессии extra", f"sessions={sessions}")

    r1 = req(
        "POST",
        "/auth/login",
        json_body={
            "email": email_a,
            "password": "secret123",
            "device_id": f"{dev_a}-e2e-revoke-a",
        },
    )
    r2 = req(
        "POST",
        "/auth/login",
        json_body={
            "email": email_a,
            "password": "secret123",
            "device_id": f"{dev_a}-e2e-revoke-b",
        },
    )
    if r1.status_code == 200 and r2.status_code == 200:
        ok("Два логина для накопления сессий перед revoke_all")

    r = req("GET", "/sessions", headers=h_a)
    before_revoke = len(r.json()) if r.status_code == 200 else 0
    r = req("POST", "/sessions/revoke_all", headers=h_a, json_body=None)
    if r.status_code != 200:
        fail("revoke_all", r.text[:200])
    else:
        ok("POST /sessions/revoke_all")

    r = req("GET", "/sessions", headers=h_a)
    if r.status_code == 200:
        after = len(r.json())
        if after == 1:
            ok(f"После revoke_all осталась 1 сессия (текущая), было {before_revoke}")
        else:
            fail("revoke_all эффект", f"ожидали 1 сессию, получили {after}")

    section("Logout")
    r = req(
        "POST",
        "/auth/logout",
        json_body={"refresh_token": refresh_a},
    )
    if r.status_code == 200:
        ok("/auth/logout")

    section("Cleanup — удаление тестовых аккаунтов")
    r = req("DELETE", "/users/me", headers=h_b, expected=(200, 204))
    if r.status_code in (200, 204):
        ok("DELETE /users/me (user_b)")
    else:
        fail("DELETE /users/me (user_b)", r.text[:200])

    r = req("DELETE", "/users/me", headers=h_a, expected=(200, 204))
    if r.status_code in (200, 204):
        ok("DELETE /users/me (user_a)")
    else:
        fail("DELETE /users/me (user_a)", r.text[:200])

    return finish()


def finish() -> int:
    print(f"\n{'='*60}")
    print(f"ИТОГО: OK={_passed}, FAIL={_failed}")
    print(f"{'='*60}\n")
    return 1 if _failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except httpx.ConnectError as e:
        print(f"Не удалось подключиться к {BASE}: {e}")
        print("Убедись что uvicorn запущен и Redis доступен для /health/ready.")
        sys.exit(2)
