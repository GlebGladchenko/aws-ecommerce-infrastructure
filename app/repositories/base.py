from abc import ABC, abstractmethod

from models.product import Product


class ProductRepository(ABC):
    """Data-access contract for products.

    The service layer depends only on this interface, so the in-memory
    implementation can be swapped for a PostgreSQL (SQLAlchemy) one by changing
    the provider in dependencies.py.
    """

    @abstractmethod
    def list_products(self) -> list[Product]:
        """Return all products ordered by ID."""

    @abstractmethod
    def get_product(self, product_id: int) -> Product | None:
        """Return the product with this ID, or None if it does not exist."""
