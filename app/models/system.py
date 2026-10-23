from typing import Literal

from pydantic import BaseModel


class HealthStatus(BaseModel):
    status: Literal["healthy"] = "healthy"


class AppInfo(BaseModel):
    name: str
    version: str
    environment: str
    docs_url: str
