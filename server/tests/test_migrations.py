import os
import subprocess
import sys
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import inspect, text

from app.db import MIGRATIONS_DIR, UnmanagedDatabase, make_engine, migrate
from app.models import Base

SERVER_DIR = Path(__file__).parent.parent


@pytest.fixture
def engine(tmp_path):
    return make_engine(f"sqlite:///{tmp_path / 'test.db'}")


def test_migrations_match_models(engine):
    """Fails when a model changed without a migration: run `alembic revision --autogenerate`."""
    migrate(engine)
    with engine.connect() as conn:
        diff = compare_metadata(MigrationContext.configure(conn, opts={"compare_type": True}), Base.metadata)
    assert diff == []


def test_migrate_twice_keeps_data(engine):
    migrate(engine)
    with engine.begin() as conn:
        conn.execute(text("UPDATE sync_state SET last_seq = 41"))
    migrate(engine)
    with engine.connect() as conn:
        assert conn.execute(text("SELECT id, last_seq FROM sync_state")).all() == [(1, 41)]


def test_downgrade_to_base_and_up_again(engine):
    migrate(engine)
    config = Config()
    config.set_main_option("script_location", str(MIGRATIONS_DIR))
    with engine.begin() as conn:
        config.attributes["connection"] = conn
        command.downgrade(config, "base")
    assert set(inspect(engine).get_table_names()) <= {"alembic_version"}
    migrate(engine)
    assert {"products", "identifiers", "sync_state"} <= set(inspect(engine).get_table_names())


def test_database_from_before_migrations_is_refused(engine):
    Base.metadata.create_all(engine)
    with pytest.raises(UnmanagedDatabase):
        migrate(engine)


def test_cli_upgrade_works_without_api_token(tmp_path):
    env = {k: v for k, v in os.environ.items() if not k.startswith("SB_")}
    env["SB_DATABASE_URL"] = f"sqlite:///{tmp_path / 'cli.db'}"
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=SERVER_DIR, env=env, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "products" in inspect(make_engine(env["SB_DATABASE_URL"])).get_table_names()
