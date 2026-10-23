from collections.abc import Iterable
from decimal import Decimal

from models.product import Product
from repositories.base import ProductRepository

SAMPLE_PRODUCTS: tuple[Product, ...] = (
    Product(
        id=1,
        name="Wireless Mouse",
        description="Ergonomic 2.4 GHz wireless mouse with a USB-C receiver.",
        price=Decimal("24.99"),
        inventory_quantity=150,
    ),
    Product(
        id=2,
        name="Mechanical Keyboard",
        description="Tenkeyless mechanical keyboard with hot-swappable switches.",
        price=Decimal("89.00"),
        inventory_quantity=40,
    ),
    Product(
        id=3,
        name="27-inch Monitor",
        description="27-inch 1440p IPS monitor with a height-adjustable stand.",
        price=Decimal("279.50"),
        inventory_quantity=12,
    ),
    Product(
        id=4,
        name="USB-C Hub",
        description="7-in-1 USB-C hub with HDMI, Ethernet and SD card reader.",
        price=Decimal("39.95"),
        inventory_quantity=0,
    ),
)


class InMemoryProductRepository(ProductRepository):
    """Read-only, process-local product store.

    Every instance serves the same fixed data and nothing is written at
    runtime, so it is safe to run behind a load balancer across many instances.
    """

    def __init__(self, products: Iterable[Product] = SAMPLE_PRODUCTS) -> None:
        self._products = {product.id: product for product in products}

    def list_products(self) -> list[Product]:
        return [self._products[product_id] for product_id in sorted(self._products)]

    def get_product(self, product_id: int) -> Product | None:
        return self._products.get(product_id)
