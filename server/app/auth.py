import secrets

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

_bearer = HTTPBearer(auto_error=False)


def require_token(
    request: Request, creds: HTTPAuthorizationCredentials | None = Depends(_bearer)
) -> None:
    expected = request.app.state.settings.api_token
    if creds is None or not secrets.compare_digest(
        creds.credentials.encode(), expected.encode()
    ):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "invalid or missing token",
            headers={"WWW-Authenticate": "Bearer"},
        )
