from collections.abc import Iterator
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from config import get_settings
from dependencies import get_product_repository
from main import app
from models.product import Product
from repositories.in_memory import SAMPLE_PRODUCTS, InMemoryProductRepository

PRODUCT_FIELDS = {"id", "name", "description", "price", "inventory_quantity"}


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def test_health_returns_200(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}


def test_root_returns_app_info(client: TestClient) -> None:
    settings = get_settings()

    response = client.get("/")

    assert response.status_code == 200
    assert response.json() == {
        "name": settings.app_name,
        "version": settings.app_version,
        "environment": settings.environment,
        "docs_url": "/docs",
    }


def test_list_products_returns_sample_products(client: TestClient) -> None:
    response = client.get("/api/products")

    assert response.status_code == 200
    body = response.json()
    assert isinstance(body, list)
    assert [item["id"] for item in body] == [product.id for product in SAMPLE_PRODUCTS]


def test_get_product_by_id(client: TestClient) -> None:
    expected = SAMPLE_PRODUCTS[0]

    response = client.get(f"/api/products/{expected.id}")

    assert response.status_code == 200
    assert response.json() == {
        "id": expected.id,
        "name": expected.name,
        "description": expected.description,
        "price": float(expected.price),
        "inventory_quantity": expected.inventory_quantity,
    }


def test_get_nonexistent_product_returns_404(client: TestClient) -> None:
    response = client.get("/api/products/999999")

    assert response.status_code == 404
    assert response.json() == {"detail": "Product 999999 not found"}


@pytest.mark.parametrize("product_id", ["0", "-1", "abc"])
def test_get_product_with_invalid_id_returns_422(client: TestClient, product_id: str) -> None:
    response = client.get(f"/api/products/{product_id}")

    assert response.status_code == 422


def test_product_response_schema(client: TestClient) -> None:
    body = client.get("/api/products").json()

    assert body, "expected at least one product"
    for item in body:
        assert set(item) == PRODUCT_FIELDS
        assert isinstance(item["id"], int)
        assert isinstance(item["name"], str) and item["name"]
        assert isinstance(item["description"], str)
        assert isinstance(item["price"], (int, float)) and item["price"] > 0
        assert isinstance(item["inventory_quantity"], int) and item["inventory_quantity"] >= 0
        Product.model_validate(item)


def test_repository_can_be_replaced(client: TestClient) -> None:
    custom = Product(
        id=42,
        name="Test Product",
        description="Injected through dependency_overrides.",
        price=Decimal("1.50"),
        inventory_quantity=3,
    )
    app.dependency_overrides[get_product_repository] = lambda: InMemoryProductRepository([custom])

    response = client.get("/api/products")

    assert response.status_code == 200
    assert [item["id"] for item in response.json()] == [42]


def test_openapi_docs_available(client: TestClient) -> None:
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200
