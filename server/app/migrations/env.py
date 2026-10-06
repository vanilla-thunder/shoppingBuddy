from alembic import context
from sqlalchemy import create_engine

from app.config import DatabaseSettings
from app.models import Base

config = context.config
target_metadata = Base.metadata


def _configure(connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        # SQLite can't ALTER most things; batch mode rebuilds the table instead.
        render_as_batch=True,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


connection = config.attributes.get("connection")
if connection is not None:
    # Called from the app (app.db.migrate) with an open connection.
    _configure(connection)
else:
    url = config.get_main_option("sqlalchemy.url") or DatabaseSettings().database_url
    engine = create_engine(url)
    with engine.connect() as conn:
        _configure(conn)
