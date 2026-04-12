from fastapi import APIRouter
from fastapi.responses import JSONResponse
from sqlalchemy import text

from db import engine
from utils.redis import redis_ping

router = APIRouter(tags=["Health"])


@router.get("/health/live")
async def liveness():
    return {"status": "ok"}


@router.get("/health/ready")
async def readiness():
    db_ok = False
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        db_ok = True
    except Exception:
        pass

    redis_ok = await redis_ping()

    if not db_ok or not redis_ok:
        return JSONResponse(
            status_code=503,
            content={
                "status": "unready",
                "database": db_ok,
                "redis": redis_ok,
            },
        )

    return {"status": "ready", "database": True, "redis": True}


@router.get("/health")
async def health_summary():
    return {"status": "ok", "service": "siberia"}
