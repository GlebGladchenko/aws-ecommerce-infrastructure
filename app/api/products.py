from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, status

from dependencies import get_product_service
from models.product import Product
from services.product_service import ProductNotFoundError, ProductService

router = APIRouter(prefix="/api/products", tags=["products"])

ProductServiceDep = Annotated[ProductService, Depends(get_product_service)]


@router.get("", response_model=list[Product], summary="List products")
def list_products(service: ProductServiceDep) -> list[Product]:
    return service.list_products()


@router.get(
    "/{product_id}",
    response_model=Product,
    summary="Get a product by ID",
    responses={status.HTTP_404_NOT_FOUND: {"description": "Product not found"}},
)
def get_product(
    product_id: Annotated[int, Path(ge=1)],
    service: ProductServiceDep,
) -> Product:
    try:
        return service.get_product(product_id)
    except ProductNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
