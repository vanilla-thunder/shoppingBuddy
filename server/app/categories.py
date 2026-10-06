import re
from urllib.parse import urlsplit

LOCAL = "local"
MAX_LENGTH = 100
_DOMAIN = re.compile(r"[\w-]+(\.[\w-]+)*")


def normalize_category(raw: str) -> str:
    """Return the canonical category: "local" (bought in a shop) or a website domain.

    Pasted URLs are reduced to their host, so "https://www.lieferando.de/menu/x" and
    "Lieferando.de" both become "lieferando.de". Clients must apply the same rules.
    """
    text = raw.strip().lower()
    if "://" in text:
        text = urlsplit(text).hostname or ""
    else:
        text = text.split("/", 1)[0].split(":", 1)[0]
    text = text.removeprefix("www.")
    if not text or len(text) > MAX_LENGTH or not _DOMAIN.fullmatch(text):
        raise ValueError("category must be 'local' or a website domain like lieferando.de")
    return text
