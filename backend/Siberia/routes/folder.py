# routes/folder.py — пользовательские папки чатов
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import delete as sa_delete, func

from db import get_db
from utils.deps import get_current_user
from models.chat_folder import ChatFolder, ChatFolderItem
from models.chat_member import ChatMember

router = APIRouter(prefix="/folders", tags=["Folders"])

_MAX_FOLDERS = 20


class FolderCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=50)


class FolderPatch(BaseModel):
    name: str = Field(..., min_length=1, max_length=50)


class FolderChatsPut(BaseModel):
    chat_ids: list[int] = Field(..., max_length=200)


class FolderOut(BaseModel):
    id: int
    name: str
    position: int
    chat_ids: list[int]


async def _get_own_folder(db: AsyncSession, user_id: int, folder_id: int) -> ChatFolder:
    folder = await db.get(ChatFolder, folder_id)
    if folder is None or folder.user_id != user_id:
        raise HTTPException(status_code=404, detail="Folder not found")
    return folder


async def _folder_out(db: AsyncSession, folder: ChatFolder) -> FolderOut:
    rows = await db.execute(
        select(ChatFolderItem.chat_id).where(ChatFolderItem.folder_id == folder.id)
    )
    return FolderOut(
        id=folder.id, name=folder.name, position=folder.position,
        chat_ids=[r[0] for r in rows.all()],
    )


@router.get("", response_model=list[FolderOut])
async def list_folders(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user_id = current["user"].id
    folders = (await db.execute(
        select(ChatFolder).where(ChatFolder.user_id == user_id).order_by(ChatFolder.position, ChatFolder.id)
    )).scalars().all()
    if not folders:
        return []
    # Батчем содержимое всех папок
    items = (await db.execute(
        select(ChatFolderItem.folder_id, ChatFolderItem.chat_id).where(
            ChatFolderItem.folder_id.in_([f.id for f in folders])
        )
    )).all()
    by_folder: dict[int, list[int]] = {}
    for fid, cid in items:
        by_folder.setdefault(fid, []).append(cid)
    return [
        FolderOut(id=f.id, name=f.name, position=f.position, chat_ids=by_folder.get(f.id, []))
        for f in folders
    ]


@router.post("", response_model=FolderOut)
async def create_folder(
    data: FolderCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user_id = current["user"].id
    count = (await db.execute(
        select(func.count()).select_from(ChatFolder).where(ChatFolder.user_id == user_id)
    )).scalar() or 0
    if count >= _MAX_FOLDERS:
        raise HTTPException(status_code=400, detail=f"Folder limit reached ({_MAX_FOLDERS})")

    folder = ChatFolder(user_id=user_id, name=data.name, position=count)
    db.add(folder)
    await db.commit()
    await db.refresh(folder)
    return FolderOut(id=folder.id, name=folder.name, position=folder.position, chat_ids=[])


@router.patch("/{folder_id}", response_model=FolderOut)
async def rename_folder(
    folder_id: int,
    data: FolderPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    folder = await _get_own_folder(db, current["user"].id, folder_id)
    folder.name = data.name
    await db.commit()
    return await _folder_out(db, folder)


@router.delete("/{folder_id}", status_code=200)
async def delete_folder(
    folder_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    folder = await _get_own_folder(db, current["user"].id, folder_id)
    await db.delete(folder)  # items каскадом (FK ondelete)
    await db.commit()
    return {"detail": "Folder deleted"}


@router.put("/{folder_id}/chats", response_model=FolderOut)
async def set_folder_chats(
    folder_id: int,
    data: FolderChatsPut,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Полная замена содержимого папки. Кладутся только чаты, где юзер состоит."""
    user_id = current["user"].id
    folder = await _get_own_folder(db, user_id, folder_id)

    # В папку можно положить только СВОИ чаты
    member_rows = await db.execute(
        select(ChatMember.chat_id).where(
            ChatMember.user_id == user_id,
            ChatMember.chat_id.in_(data.chat_ids or [-1]),
        )
    )
    allowed = {r[0] for r in member_rows.all()}
    rejected = [cid for cid in data.chat_ids if cid not in allowed]
    if rejected:
        raise HTTPException(status_code=403, detail=f"Not a member of chats: {rejected}")

    await db.execute(sa_delete(ChatFolderItem).where(ChatFolderItem.folder_id == folder.id))
    for cid in dict.fromkeys(data.chat_ids):  # dedupe, порядок сохраняем
        db.add(ChatFolderItem(folder_id=folder.id, chat_id=cid))
    await db.commit()
    return await _folder_out(db, folder)
