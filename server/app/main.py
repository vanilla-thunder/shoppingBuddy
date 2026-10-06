from pathlib import Path
from urllib.parse import urlencode

from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import sessionmaker
from starlette.middleware.sessions import SessionMiddleware

from app.api import products, sync
from app.config import Settings
from app.db import make_engine, migrate
from app.web import routes as web
from app.web.session import LoginRequired

VERSION = "0.2.0"
SESSION_MAX_AGE = 60 * 60 * 24 * 30


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    engine = make_engine(settings.database_url)
    migrate(engine)

    app = FastAPI(title="shoppingBuddy", version=VERSION)
    app.state.settings = settings
    app.state.sessionmaker = sessionmaker(engine)
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.session_secret,
        session_cookie="sb_session",
        max_age=SESSION_MAX_AGE,
        same_site="lax",
        https_only=settings.secure_cookies,
    )
    web.templates.env.globals["version"] = VERSION

    app.mount("/static", StaticFiles(directory=Path(web.__file__).parent / "static"), name="static")
    app.include_router(products.router)
    app.include_router(sync.router)
    app.include_router(web.public)
    app.include_router(web.router)

    @app.exception_handler(LoginRequired)
    def _to_login(request: Request, _exc: LoginRequired) -> Response:
        target = request.url.path + (f"?{request.url.query}" if request.url.query else "")
        if request.headers.get("HX-Request"):
            # htmx would swap a redirect's body into the page; make it navigate instead.
            return Response(headers={"HX-Redirect": "/login"})
        return RedirectResponse(
            "/login?" + urlencode({"next": target}) if target != "/" else "/login", status_code=303
        )

    @app.get("/health", tags=["meta"])
    def health():
        return {"status": "ok"}

    return app
