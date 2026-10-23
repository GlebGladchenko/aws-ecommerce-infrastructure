from models.product import Product
from repositories.base import ProductRepository


class ProductNotFoundError(Exception):
    def __init__(self, product_id: int) -> None:
        super().__init__(f"Product {product_id} not found")
        self.product_id = product_id


class ProductService:
    """Business logic for products; independent of HTTP and of storage."""

    def __init__(self, repository: ProductRepository) -> None:
        self._repository = repository

    def list_products(self) -> list[Product]:
        return self._repository.list_products()

    def get_product(self, product_id: int) -> Product:
        product = self._repository.get_product(product_id)
        if product is None:
            raise ProductNotFoundError(product_id)
        return product
