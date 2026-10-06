from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

from app.categories import LOCAL, normalize_category
from app.identifiers import normalize_identifier

IdentifierType = Literal["gtin", "store_article"]
PushStatus = Literal["applied", "stale", "ignored_merged", "duplicate", "rejected"]


class _In(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)


class IdentifierFields(_In):
    type: IdentifierType
    value: str = Field(min_length=1, max_length=64)
    store: str = Field("", max_length=100)

    @model_validator(mode="after")
    def _normalize(self):
        self.value, self.store = normalize_identifier(self.type, self.value, self.store)
        return self


class ProductFields(_In):
    name: str = Field(min_length=1, max_length=300)
    brand: str | None = Field(None, max_length=200)
    rating: int | None = Field(None, ge=1, le=5)
    notes: str | None = Field(None, max_length=2000)
    category: str = LOCAL

    @field_validator("category")
    @classmethod
    def _normalize_category(cls, value: str) -> str:
        return normalize_category(value)


# --- web/CRUD API ---


class ProductCreate(ProductFields):
    identifiers: list[IdentifierFields] = []


class ProductUpdate(_In):
    """Partial update: only fields present in the request body are changed; null clears."""

    name: str | None = Field(None, min_length=1, max_length=300)
    brand: str | None = Field(None, max_length=200)
    rating: int | None = Field(None, ge=1, le=5)
    notes: str | None = Field(None, max_length=2000)
    category: str | None = None

    @field_validator("category")
    @classmethod
    def _normalize_category(cls, value: str | None) -> str | None:
        return normalize_category(value) if value is not None else None

    @model_validator(mode="after")
    def _required_not_null(self):
        for field in ("name", "category"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self


class IdentifierOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    type: IdentifierType
    value: str
    store: str


class ProductOut(BaseModel):
    id: str
    name: str
    brand: str | None
    rating: int | None
    notes: str | None
    category: str
    created_at: AwareDatetime
    updated_at: AwareDatetime
    identifiers: list[IdentifierOut]


class CategoryOut(BaseModel):
    category: str
    count: int


# --- sync API ---


class ProductSyncIn(ProductFields):
    id: UUID
    created_at: AwareDatetime
    updated_at: AwareDatetime
    deleted: bool = False


class IdentifierSyncIn(IdentifierFields):
    id: UUID
    product_id: UUID
    created_at: AwareDatetime
    updated_at: AwareDatetime
    deleted: bool = False


class ProductSyncOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    brand: str | None
    rating: int | None
    notes: str | None
    category: str
    created_at: AwareDatetime
    updated_at: AwareDatetime
    deleted: bool
    merged_into: str | None
    server_seq: int


class IdentifierSyncOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    product_id: str
    type: IdentifierType
    value: str
    store: str
    created_at: AwareDatetime
    updated_at: AwareDatetime
    deleted: bool
    server_seq: int


class PushRequest(BaseModel):
    products: list[ProductSyncIn] = Field(default_factory=list, max_length=5000)
    identifiers: list[IdentifierSyncIn] = Field(default_factory=list, max_length=5000)


class PushResult(BaseModel):
    id: str
    status: PushStatus
    detail: str | None = None


class Merge(BaseModel):
    merged: str
    into: str


class PushResponse(BaseModel):
    products: list[PushResult]
    identifiers: list[PushResult]
    merges: list[Merge]


class PullResponse(BaseModel):
    products: list[ProductSyncOut]
    identifiers: list[IdentifierSyncOut]
    last_seq: int
    has_more: bool
