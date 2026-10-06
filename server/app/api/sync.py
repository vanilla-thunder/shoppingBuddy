from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app import services
from app.auth import require_token
from app.db import get_db
from app.schemas import PullResponse, PushRequest, PushResponse

router = APIRouter(prefix="/sync", tags=["sync"], dependencies=[Depends(require_token)])


@router.post("/push", response_model=PushResponse)
def push(body: PushRequest, db: Session = Depends(get_db)):
    result = services.apply_push(db, body)
    db.commit()
    return result


@router.get("/pull", response_model=PullResponse)
def pull(
    since: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=2000),
    db: Session = Depends(get_db),
):
    return services.pull(db, since, limit)
