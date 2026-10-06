from datetime import datetime, timezone

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    TypeDecorator,
    text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class UTCDateTime(TypeDecorator):
    """Stores naive UTC, returns aware UTC. Rejects naive input so LWW comparisons stay sound."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("naive datetime not allowed")
        return value.astimezone(timezone.utc).replace(tzinfo=None)

    def process_result_value(self, value: datetime | None, dialect):
        return value.replace(tzinfo=timezone.utc) if value is not None else None


class Base(DeclarativeBase):
    pass


class SyncState(Base):
    """Single row holding the global change counter that feeds every server_seq."""

    __tablename__ = "sync_state"

    id: Mapped[int] = mapped_column(primary_key=True)
    last_seq: Mapped[int] = mapped_column(default=0)


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (
        CheckConstraint("rating IS NULL OR rating BETWEEN 1 AND 5", name="ck_rating_range"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(300))
    brand: Mapped[str | None] = mapped_column(String(200))
    rating: Mapped[int | None]
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    deleted: Mapped[bool] = mapped_column(default=False)
    # Set when this product was folded into another one because both carried the same barcode.
    merged_into: Mapped[str | None] = mapped_column(ForeignKey("products.id"))
    server_seq: Mapped[int] = mapped_column(index=True)

    identifiers: Mapped[list["Identifier"]] = relationship(
        back_populates="product", order_by="Identifier.created_at"
    )


class Identifier(Base):
    __tablename__ = "identifiers"
    __table_args__ = (
        # Only live identifiers must be unique, so a deleted barcode can be reused.
        Index(
            "uq_identifier_live",
            "type",
            "value",
            "store",
            unique=True,
            sqlite_where=text("NOT deleted"),
            postgresql_where=text("NOT deleted"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    type: Mapped[str] = mapped_column(String(20))
    value: Mapped[str] = mapped_column(String(64))
    # Empty string rather than NULL, so the unique index treats "no store" as one value.
    store: Mapped[str] = mapped_column(String(100), default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)
    deleted: Mapped[bool] = mapped_column(default=False)
    server_seq: Mapped[int] = mapped_column(index=True)

    product: Mapped[Product] = relationship(back_populates="identifiers")
