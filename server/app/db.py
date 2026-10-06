from collections.abc import Iterator
from pathlib import Path

from alembic import command
from alembic.config import Config
from fastapi import Request
from sqlalchemy import Engine, create_engine, event, inspect
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def make_engine(url: str) -> Engine:
    kwargs = {}
    if url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
        if url in ("sqlite://", "sqlite:///:memory:"):
            kwargs["poolclass"] = StaticPool
    engine = create_engine(url, **kwargs)

    if engine.dialect.name == "sqlite":

        @event.listens_for(engine, "connect")
        def _enable_foreign_keys(dbapi_conn, _record):
            cursor = dbapi_conn.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    return engine


class UnmanagedDatabase(RuntimeError):
    pass


def migrate(engine: Engine) -> None:
    """Bring the schema up to the newest migration (no-op when already current)."""
    tables = set(inspect(engine).get_table_names())
    if "products" in tables and "alembic_version" not in tables:
        raise UnmanagedDatabase(
            "This database was created before migrations existed and its schema is unknown. "
            "Move the database file aside and start the server again to create a fresh one."
        )
    config = Config()
    config.set_main_option("script_location", str(MIGRATIONS_DIR))
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")


def get_db(request: Request) -> Iterator[Session]:
    db = request.app.state.sessionmaker()
    try:
        yield db
    finally:
        db.close()
