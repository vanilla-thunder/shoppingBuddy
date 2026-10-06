import hashlib
import hmac

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class DatabaseSettings(BaseSettings):
    """The part of the configuration that migrations need; no token required."""

    model_config = SettingsConfigDict(env_prefix="SB_", env_file=".env", extra="ignore")

    database_url: str = "sqlite:///./shoppingbuddy.db"


class Settings(DatabaseSettings):
    api_token: str = Field(min_length=16)
    # Mark the web session cookie Secure; enable when served over HTTPS.
    secure_cookies: bool = False

    @property
    def session_secret(self) -> str:
        # Derived from the token, so rotating the token also logs out every browser session.
        return hmac.new(self.api_token.encode(), b"shoppingbuddy-session", hashlib.sha256).hexdigest()
