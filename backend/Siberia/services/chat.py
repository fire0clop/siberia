from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import desc, func

from fastapi import HTTPException

from models.chat import Chat, ChatType
from models.chat_member import ChatMember, MemberRole
from models.user import User
from models.privacy_settings import Visibility
from services.block_service import check_not_blocked
from services.user_service import _get_privacy, _are_friends


async def lock_private_pair(db: AsyncSession, user1: int, user2: int) -> None:
    """Транзакционный advisory-lock на пару пользователей.

    Сериализует создание DM между одной парой: без него параллельные «первые
    сообщения» (POST /messages, POST /chats) наперегонки проходили проверку
    get_private_chat_between → None и создавали несколько дублей одного DM.
    Лок отпускается автоматически на commit/rollback.
    """
    lo, hi = sorted((user1, user2))
    key = (lo << 32) | (hi & 0xFFFFFFFF)
    from sqlalchemy import text
    await db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})


async def get_private_chat_between(
    db: AsyncSession, user1: int, user2: int
) -> Chat | None:
    """Two-member chat with exactly user1 and user2 (not a group that contains both)."""
    if user1 == user2:
        return None

    two_member_chats = (
        select(ChatMember.chat_id)
        .group_by(ChatMember.chat_id)
        .having(func.count(ChatMember.user_id) == 2)
        .subquery()
    )

    stmt = (
        select(Chat)
        .join(two_member_chats, Chat.id == two_member_chats.c.chat_id)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        # Только private: двухместная ГРУППА между теми же людьми — не DM
        .where(
            ChatMember.user_id.in_([user1, user2]),
            Chat.type == ChatType.private,
        )
        .group_by(Chat.id)
        .having(func.count(ChatMember.user_id) == 2)
    )

    result = await db.execute(stmt)
    return result.scalars().first()


async def _check_can_message(db: AsyncSession, sender_id: int, recipient_id: int) -> None:
    """
    Enforce messaging privacy for new private chats.
    Raises 403 if the recipient doesn't want messages from this sender.
    Should only be called when no existing chat exists yet.
    """
    await check_not_blocked(db, sender_id, recipient_id)

    ps = await _get_privacy(db, recipient_id)
    if ps.messages_from == Visibility.everyone:
        return
    if ps.messages_from == Visibility.friends:
        if await _are_friends(db, sender_id, recipient_id):
            return
        raise HTTPException(
            status_code=403,
            detail="This user only accepts messages from friends",
        )
    # nobody
    raise HTTPException(
        status_code=403,
        detail="This user does not accept new messages",
    )


async def create_chat(
    db: AsyncSession,
    creator_id: int,
    user_ids: list[int],
    title: str | None,
):
    all_users = set(user_ids)
    all_users.add(creator_id)

    users = await db.execute(select(User.id).where(User.id.in_(all_users)))
    found_users = {u[0] for u in users.all()}

    if found_users != all_users:
        raise HTTPException(status_code=404, detail="Some users not found")

    if len(all_users) == 2:
        user_list = list(all_users)
        other_id = user_list[0] if user_list[1] == creator_id else user_list[1]

        # Return existing chat immediately — no privacy check needed
        existing = await get_private_chat_between(db, creator_id, other_id)
        if existing:
            return existing

        # New chat: enforce messaging privacy + block check.
        # _check_can_message коммитит (через _get_privacy), поэтому advisory-lock
        # берём ПОСЛЕ него и держим до commit создания — иначе конкурентные
        # POST /chats плодили дубли одного DM (см. lock_private_pair).
        await _check_can_message(db, creator_id, other_id)

        await lock_private_pair(db, creator_id, other_id)
        existing = await get_private_chat_between(db, creator_id, other_id)
        if existing:
            return existing

    chat = Chat(title=title)
    db.add(chat)
    await db.flush()

    now = datetime.now(timezone.utc)
    db.add_all([
        ChatMember(chat_id=chat.id, user_id=uid, role=MemberRole.member, joined_at=now)
        for uid in all_users
    ])

    await db.commit()
    await db.refresh(chat)
    return chat


async def create_secret_chat(
    db: AsyncSession, creator_id: int, peer_id: int, eph_pub: str
) -> Chat:
    """Секретный E2E-чат: сервер хранит только handshake-материал.

    Ключ чата обе стороны выводят сами:
      creator: X25519(eph_priv,  peer_identity_pub)
      peer:    X25519(id_priv,   eph_pub)
    → HKDF → AES-GCM. Plaintext сервера не достигает.
    """
    from models.e2e_key import E2EKey

    if creator_id == peer_id:
        raise HTTPException(status_code=400, detail="Cannot start a secret chat with yourself")

    peer = await db.get(User, peer_id)
    if peer is None or peer.deleted_at is not None:
        raise HTTPException(status_code=404, detail="User not found")

    # Блокировки и privacy — как у обычного DM
    await _check_can_message(db, creator_id, peer_id)

    creator_key = await db.get(E2EKey, creator_id)
    if creator_key is None:
        raise HTTPException(status_code=409, detail="Publish your E2E key first (PUT /e2e/keys)")
    peer_key = await db.get(E2EKey, peer_id)
    if peer_key is None:
        raise HTTPException(status_code=409, detail="Peer has no E2E key yet")

    chat = Chat(
        type=ChatType.secret,
        e2e_handshake={
            "v": 1,
            "creator_id": creator_id,
            "eph_pub": eph_pub,
            "creator_identity_pub": creator_key.public_key,
            "peer_identity_pub": peer_key.public_key,
        },
    )
    db.add(chat)
    await db.flush()

    now = datetime.now(timezone.utc)
    db.add_all([
        ChatMember(chat_id=chat.id, user_id=creator_id, role=MemberRole.member, joined_at=now),
        ChatMember(chat_id=chat.id, user_id=peer_id, role=MemberRole.member, joined_at=now),
    ])
    await db.commit()
    await db.refresh(chat)
    return chat


async def get_or_create_saved_chat(db: AsyncSession, user_id: int) -> Chat:
    result = await db.execute(
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(ChatMember.user_id == user_id, Chat.type == ChatType.saved)
    )
    chat = result.scalars().first()
    if chat:
        return chat

    chat = Chat(type=ChatType.saved, title="Saved Messages", max_members=1)
    db.add(chat)
    await db.flush()

    db.add(ChatMember(chat_id=chat.id, user_id=user_id, role=MemberRole.owner, joined_at=datetime.now(timezone.utc)))
    await db.commit()
    await db.refresh(chat)
    return chat


async def pin_message(db: AsyncSession, user_id: int, chat_id: int, message_id: int | None) -> None:
    from models.chat_update import ChatUpdateEventType
    from models.chat_member import MemberRole
    from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope

    result = await db.execute(
        select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
    )
    member = result.scalars().first()
    if not member:
        raise HTTPException(status_code=403, detail="Access denied")

    chat = await lock_chat_row(db, chat_id)

    # В личном чате роли только member — закрепить может любой из двоих
    # (раньше pin в DM был невозможен: требовался admin/owner). В группах
    # и каналах — по-прежнему только админы.
    if chat.type != ChatType.private and member.role not in (MemberRole.admin, MemberRole.owner):
        raise HTTPException(status_code=403, detail="Only admins and owner can pin messages")

    # Сообщение должно существовать и принадлежать ЭТОМУ чату —
    # раньше можно было закрепить id из любого чужого чата.
    if message_id is not None:
        from models.message import Message as _Message
        msg = await db.get(_Message, message_id)
        if msg is None or msg.chat_id != chat_id or msg.deleted_at is not None:
            raise HTTPException(status_code=400, detail="Message not found in this chat")

    chat.pinned_message_id = message_id

    seq, _ = await log_update_on_locked_chat(
        db, chat, ChatUpdateEventType.message_pinned, message_id,
        {"pinned_message_id": message_id},
    )
    await db.commit()

    env = build_envelope(
        chat_id, seq, ChatUpdateEventType.message_pinned, message_id,
        {"pinned_message_id": message_id},
    )
    await broadcast_envelope(chat_id, env)


async def get_user_chats(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(Chat)
        .join(ChatMember)
        .where(ChatMember.user_id == user_id)
        .order_by(desc(Chat.last_message_id).nulls_last(), desc(Chat.id))
    )
    return result.scalars().all()


async def enrich_chats_for_list(db: AsyncSession, viewer_id: int, chats: list) -> dict[int, dict]:
    """Батч-обогащение списка чатов: unread, последнее сообщение, собеседник DM.

    Все запросы батчевые (константное число независимо от размера списка),
    чтобы убрать N+1 на клиенте и reload-шторм. Возвращает chat_id → dict.
    """
    from models.message import Message
    from models.message_status import MessageStatus, MessageStatusEnum
    from models.chat_member import ChatMember as _ChatMember
    from models.media import Media as _Media
    from services.user_service import build_user_out
    from sqlalchemy import func as _func

    chat_ids = [c.id for c in chats]
    result: dict[int, dict] = {
        cid: {"unread_count": 0, "last_message": None, "peer": None, "is_archived": False}
        for cid in chat_ids
    }
    if not chat_ids:
        return result

    # 0) архив per-user — из членства
    arch_rows = await db.execute(
        select(_ChatMember.chat_id, _ChatMember.archived_at).where(
            _ChatMember.user_id == viewer_id,
            _ChatMember.chat_id.in_(chat_ids),
        )
    )
    for cid, archived_at in arch_rows.all():
        result[cid]["is_archived"] = archived_at is not None

    # 1) unread per chat: непрочитанные статусы viewer'а, только отправленные
    #    и не удалённые сообщения (scheduled статусов больше не создаёт, но
    #    фильтр send_at защищает исторические данные).
    unread_rows = await db.execute(
        select(Message.chat_id, _func.count())
        .join(MessageStatus, MessageStatus.message_id == Message.id)
        .where(
            Message.chat_id.in_(chat_ids),
            MessageStatus.user_id == viewer_id,
            MessageStatus.status != MessageStatusEnum.read,
            Message.deleted_at.is_(None),
            Message.send_at.is_(None),
        )
        .group_by(Message.chat_id)
    )
    for cid, cnt in unread_rows.all():
        result[cid]["unread_count"] = int(cnt)

    # 2) last message per chat — батчем по chat.last_message_id
    last_ids = {c.last_message_id: c.id for c in chats if c.last_message_id is not None}
    if last_ids:
        msg_rows = await db.execute(
            select(Message).where(Message.id.in_(list(last_ids.keys())))
        )
        media_ids = set()
        msgs = list(msg_rows.scalars().all())
        for m in msgs:
            if m.media_id:
                media_ids.add(m.media_id)
        media_types: dict = {}
        if media_ids:
            mrows = await db.execute(select(_Media).where(_Media.id.in_(list(media_ids))))
            for m in mrows.scalars().all():
                media_types[m.id] = m.type.value
        for m in msgs:
            result[m.chat_id]["last_message"] = {
                "id": m.id,
                "user_id": m.user_id,
                "text": None if m.deleted_at else m.text,
                "media_type": media_types.get(m.media_id) if not m.deleted_at else None,
                "created_at": m.created_at,
                "deleted": m.deleted_at is not None,
            }

    # 3) peer для приватных чатов — батчем участников, затем build_user_out
    # peer нужен и приватным, и секретным чатам (оба 1-на-1)
    private_ids = [c.id for c in chats if getattr(c.type, "value", c.type) in ("private", "secret")]
    if private_ids:
        member_rows = await db.execute(
            select(_ChatMember.chat_id, _ChatMember.user_id).where(
                _ChatMember.chat_id.in_(private_ids),
                _ChatMember.user_id != viewer_id,
            )
        )
        peer_by_chat = {cid: uid for cid, uid in member_rows.all()}
        for cid, peer_uid in peer_by_chat.items():
            peer_user = await db.get(User, peer_uid)
            if peer_user:
                result[cid]["peer"] = await build_user_out(db, peer_user, viewer_id=viewer_id)

    return result


async def upsert_draft(db: AsyncSession, user_id: int, chat_id: int, text: str) -> None:
    from models.chat_draft import ChatDraft
    await check_user_in_chat(db, user_id, chat_id)
    result = await db.execute(
        select(ChatDraft).where(ChatDraft.chat_id == chat_id, ChatDraft.user_id == user_id)
    )
    draft = result.scalars().first()
    if draft:
        draft.text = text
    else:
        db.add(ChatDraft(chat_id=chat_id, user_id=user_id, text=text))
    await db.commit()


async def delete_draft(db: AsyncSession, user_id: int, chat_id: int) -> None:
    from models.chat_draft import ChatDraft
    result = await db.execute(
        select(ChatDraft).where(ChatDraft.chat_id == chat_id, ChatDraft.user_id == user_id)
    )
    draft = result.scalars().first()
    if draft:
        await db.delete(draft)
        await db.commit()


async def check_can_read_chat(db: AsyncSession, user_id: int, chat_id: int):
    """Читать чат может участник — или кто угодно, если это публичный канал.

    Раньше публичный канал нельзя было даже посмотреть без подписки:
    GET /chats/{id}/messages требовал членства.
    """
    result = await db.execute(
        select(ChatMember.id).where(
            ChatMember.user_id == user_id,
            ChatMember.chat_id == chat_id,
        )
    )
    if result.scalar():
        return
    chat = await db.get(Chat, chat_id)
    if chat is not None and chat.type == ChatType.channel and chat.is_public:
        return
    raise HTTPException(status_code=403, detail="Access denied")


async def check_user_in_chat(db: AsyncSession, user_id: int, chat_id: int):
    stmt = select(ChatMember.id).where(
        ChatMember.user_id == user_id,
        ChatMember.chat_id == chat_id,
    )
    result = await db.execute(stmt)
    if not result.scalar():
        raise HTTPException(status_code=403, detail="Access denied")
