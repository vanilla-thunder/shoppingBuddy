from fastapi import FastAPI
from sqlalchemy.orm import sessionmaker

from app.api import products, sync
from app.config import Settings
from app.db import init_db, make_engine


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    engine = make_engine(settings.database_url)
    init_db(engine)

    app = FastAPI(title="shoppingBuddy", version="0.1.0")
    app.state.settings = settings
    app.state.sessionmaker = sessionmaker(engine)
    app.include_router(products.router)
    app.include_router(sync.router)

    @app.get("/health", tags=["meta"])
    def health():
        return {"status": "ok"}

    return app
