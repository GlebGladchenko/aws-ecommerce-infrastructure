"""FastAPI entry point: `uvicorn main:app`."""

import logging
import sys

from fastapi import FastAPI

from api import products, system
from config import get_settings


def configure_logging(level: str) -> None:
    # stdout only: Docker's log driver (and later the CloudWatch agent) collects it.
    logging.basicConfig(
        level=level.upper(),
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        force=True,
    )


def create_app() -> FastAPI:
    settings = get_settings()
    configure_logging(settings.log_level)

    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        description="Product catalogue API for the AWS e-commerce platform.",
    )
    app.include_router(system.router)
    app.include_router(products.router)

    logging.getLogger(__name__).info(
        "Starting %s %s (environment=%s)",
        settings.app_name,
        settings.app_version,
        settings.environment,
    )
    return app


app = create_app()
