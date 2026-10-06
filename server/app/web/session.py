import secrets
from urllib.parse import urlsplit

from fastapi import HTTPException, Request, status


class LoginRequired(Exception):
    pass


def is_logged_in(request: Request) -> bool:
    return request.session.get("auth") is True


def require_session(request: Request) -> None:
    if not is_logged_in(request):
        raise LoginRequired()


def check_token(request: Request, token: str) -> bool:
    return secrets.compare_digest(token.encode(), request.app.state.settings.api_token.encode())


def check_origin(request: Request) -> None:
    """CSRF guard for form posts, on top of the SameSite=Lax session cookie."""
    if request.method in ("GET", "HEAD", "OPTIONS"):
        return
    origin = request.headers.get("origin")
    if origin is not None and urlsplit(origin).netloc != request.headers.get("host"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "cross-origin request refused")


def safe_next(target: str | None) -> str:
    """Only allow local redirect targets after login."""
    # Browsers treat "\" like "/", so "/\evil.com" would be protocol-relative too.
    if target and target.startswith("/") and not target.startswith("//") and "\\" not in target:
        return target
    return "/"
