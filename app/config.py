"""Application configuration read from environment variables.

Every setting has a safe default so the app starts with no configuration at
all (locally, in Docker, or on EC2 before secrets are wired in). Nothing here
may hold credentials; database secrets will come from AWS Secrets Manager.
"""

import os
from functools import lru_cache

from pydantic import BaseModel, ConfigDict, Field


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True)

    app_name: str = "ecommerce-api"
    app_version: str = "0.1.0"
    environment: str = Field(default="local", description="local, dev or prod")
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> "Settings":
        """Build settings from APP_NAME, APP_VERSION, APP_ENV and LOG_LEVEL."""
        env_map = {
            "app_name": "APP_NAME",
            "app_version": "APP_VERSION",
            "environment": "APP_ENV",
            "log_level": "LOG_LEVEL",
        }
        values = {field: os.environ[var] for field, var in env_map.items() if os.environ.get(var)}
        return cls(**values)


@lru_cache
def get_settings() -> Settings:
    return Settings.from_env()
