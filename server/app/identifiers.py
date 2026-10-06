import re

GTIN_LENGTHS = (8, 12, 13, 14)
_DIGITS = re.compile(r"[0-9]+")


def gtin_check_digit_ok(code: str) -> bool:
    digits = [int(c) for c in code]
    body, check = digits[:-1], digits[-1]
    total = sum(d * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(body)))
    return (10 - total % 10) % 10 == check


def normalize_identifier(type_: str, value: str, store: str | None) -> tuple[str, str]:
    """Return the canonical (value, store) pair. Clients must apply the same rules.

    GTINs (EAN-8, UPC-A, EAN-13, GTIN-14) are stored zero-padded to 14 digits, so a UPC-A
    and the EAN-13 a scanner reports for the same item compare equal. Store article numbers
    are scoped to a store, matched case-insensitively.
    """
    value = value.strip()
    store = (store or "").strip()
    if type_ == "gtin":
        if not _DIGITS.fullmatch(value) or len(value) not in GTIN_LENGTHS:
            raise ValueError("GTIN must be 8, 12, 13 or 14 digits")
        if not gtin_check_digit_ok(value):
            raise ValueError("GTIN check digit is wrong")
        if store:
            raise ValueError("GTIN must not have a store")
        return value.zfill(14), ""
    if type_ == "store_article":
        if not value:
            raise ValueError("article number must not be empty")
        if not store:
            raise ValueError("store article number needs a store")
        return value, store.casefold()
    raise ValueError(f"unknown identifier type {type_!r}")
