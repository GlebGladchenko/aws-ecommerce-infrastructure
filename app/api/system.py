from typing import Annotated

from fastapi import APIRouter, Depends

from config import Settings, get_settings
from models.system import AppInfo, HealthStatus

router = APIRouter(tags=["system"])


@router.get("/", response_model=AppInfo, summary="Application information")
def root(settings: Annotated[Settings, Depends(get_settings)]) -> AppInfo:
    return AppInfo(
        name=settings.app_name,
        version=settings.app_version,
        environment=settings.environment,
        docs_url="/docs",
    )


# Used by the ALB target group health check. It must stay free of external
# dependencies (database, AWS APIs): a failing dependency would otherwise make
# every instance unhealthy at once and the ASG would replace them in a loop.
@router.get("/health", response_model=HealthStatus, summary="Liveness check for the load balancer")
def health() -> HealthStatus:
    return HealthStatus()
