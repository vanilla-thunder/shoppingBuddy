from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SB_", env_file=".env")

    api_token: str = Field(min_length=16)
    database_url: str = "sqlite:///./shoppingbuddy.db"
