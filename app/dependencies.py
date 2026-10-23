"""FastAPI dependency providers.

Routes receive services through Depends(), so tests can replace any layer with
app.dependency_overrides, and switching storage to PostgreSQL only changes
get_product_repository().
"""

from functools import lru_cache
from typing import Annotated

from fastapi import Depends

from repositories.base import ProductRepository
from repositories.in_memory import InMemoryProductRepository
from services.product_service import ProductService


@lru_cache
def get_product_repository() -> ProductRepository:
    # TODO: return a SQLAlchemy-backed repository once RDS is available.
    return InMemoryProductRepository()


def get_product_service(
    repository: Annotated[ProductRepository, Depends(get_product_repository)],
) -> ProductService:
    return ProductService(repository)
