import logging

from fastapi import Request, HTTPException
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError

logger = logging.getLogger("siberia.errors")


def _rid(request: Request) -> str | None:
    return getattr(request.state, "request_id", None)


async def http_exception_handler(request: Request, exc: HTTPException):
    detail = exc.detail
    if isinstance(detail, str):
        message = detail
        fields = None
    else:
        message = "Request failed"
        fields = detail
    body = {
        "error": {
            "code": f"http_{exc.status_code}",
            "message": message,
            "request_id": _rid(request),
        }
    }
    if fields is not None:
        body["error"]["fields"] = fields
    return JSONResponse(status_code=exc.status_code, content=body)


async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={
            "error": {
                "code": "validation_error",
                "message": "Validation failed",
                "request_id": _rid(request),
                "fields": exc.errors(),
            }
        },
    )


async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception(
        "unhandled error request_id=%s path=%s",
        _rid(request),
        request.url.path,
        exc_info=exc,
    )
    return JSONResponse(
        status_code=500,
        content={
            "error": {
                "code": "internal_error",
                "message": "Internal server error",
                "request_id": _rid(request),
            }
        },
    )
