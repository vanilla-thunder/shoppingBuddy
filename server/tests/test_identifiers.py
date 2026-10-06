import pytest

from app.identifiers import normalize_identifier
from tests.conftest import EAN8, EAN13, UPC_A


@pytest.mark.parametrize("code", [EAN13, UPC_A, EAN8, "0" + EAN13])
def test_valid_gtins_are_padded_to_14_digits(code):
    value, store = normalize_identifier("gtin", f"  {code} ", None)
    assert value == code.zfill(14)
    assert store == ""


def test_upc_a_and_its_ean13_form_are_equal():
    assert normalize_identifier("gtin", UPC_A, "") == normalize_identifier("gtin", "0" + UPC_A, "")


@pytest.mark.parametrize("code", ["4006381333932", "12345", "40063813339a1", "４００６３８１３３３９３１"])
def test_invalid_gtins_rejected(code):
    with pytest.raises(ValueError):
        normalize_identifier("gtin", code, "")


def test_store_article_requires_store_and_casefolds_it():
    assert normalize_identifier("store_article", "12345", " ALDI ") == ("12345", "aldi")
    with pytest.raises(ValueError):
        normalize_identifier("store_article", "12345", "")
