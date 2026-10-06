from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

TOKEN = "test-token-0123456789"

# Valid barcodes (correct check digits).
EAN13 = "4006381333931"
EAN13_B = "5901234123457"
UPC_A = "036000291452"
EAN8 = "96385074"

BASE_TIME = datetime(2026, 1, 1, tzinfo=timezone.utc)


@pytest.fixture
def client():
    app = create_app(Settings(api_token=TOKEN, database_url="sqlite://"))
    with TestClient(app, headers={"Authorization": f"Bearer {TOKEN}"}) as c:
        yield c


def ts(minutes: int) -> str:
    return (BASE_TIME + timedelta(minutes=minutes)).isoformat()


def new_id() -> str:
    return str(uuid4())


def sync_product(pid: str, name: str, at: int, **extra) -> dict:
    return {"id": pid, "name": name, "created_at": ts(at), "updated_at": ts(at), **extra}


def sync_identifier(iid: str, pid: str, value: str, at: int, **extra) -> dict:
    return {
        "id": iid,
        "product_id": pid,
        "type": "gtin",
        "value": value,
        "created_at": ts(at),
        "updated_at": ts(at),
        **extra,
    }
