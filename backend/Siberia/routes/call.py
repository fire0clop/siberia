# routes/call.py
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from schemas.call import CallInitiate, CallOut, CallWithPeers
from schemas.user import UserOut
from services.user_service import build_user_out
from services.call_service import (
    initiate_call,
    accept_call,
    decline_call,
    cancel_call,
    end_call,
    list_history,
)

router = APIRouter(prefix="/calls", tags=["Calls"])


@router.post("", response_model=CallOut)
async def initiate(
    body: CallInitiate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    call = await initiate_call(
        db,
        caller_id=current["user"].id,
        callee_id=body.callee_id,
        call_type=body.type,
    )
    return call


@router.post("/{call_id}/accept", response_model=CallOut)
async def accept(
    call_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await accept_call(db, call_id, current["user"].id)


@router.post("/{call_id}/decline", response_model=CallOut)
async def decline(
    call_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await decline_call(db, call_id, current["user"].id)


@router.post("/{call_id}/cancel", response_model=CallOut)
async def cancel(
    call_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await cancel_call(db, call_id, current["user"].id)


@router.post("/{call_id}/end", response_model=CallOut)
async def end(
    call_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await end_call(db, call_id, current["user"].id)


@router.get("/history", response_model=list[CallWithPeers])
async def history(
    limit: int = 50,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    viewer_id = current["user"].id
    calls = await list_history(db, viewer_id, limit=min(max(limit, 1), 200))
    # Build peers via build_user_out so privacy filtering applies
    # (raw ORM → UserOut leaked email and last_seen_at).
    result = []
    for c in calls:
        caller = UserOut(**await build_user_out(db, c.caller, viewer_id=viewer_id))
        callee = UserOut(**await build_user_out(db, c.callee, viewer_id=viewer_id))
        result.append(
            CallWithPeers(
                **CallOut.model_validate(c).model_dump(),
                caller=caller,
                callee=callee,
            )
        )
    return result
