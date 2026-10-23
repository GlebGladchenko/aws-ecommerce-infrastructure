from decimal import Decimal
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, PlainSerializer

# Decimal avoids float rounding errors in money and maps directly to a
# PostgreSQL NUMERIC(10, 2) column later; it is emitted as a JSON number.
Price = Annotated[
    Decimal,
    Field(gt=0, max_digits=10, decimal_places=2, examples=[19.99]),
    PlainSerializer(float, return_type=float, when_used="json"),
]


class Product(BaseModel):
    """A catalogue product as returned by the API."""

    # from_attributes lets a future SQLAlchemy repository return ORM rows
    # through Product.model_validate(row).
    model_config = ConfigDict(frozen=True, from_attributes=True)

    id: int = Field(ge=1, examples=[1])
    name: str = Field(min_length=1, max_length=200, examples=["Wireless Mouse"])
    description: str = Field(max_length=2000, examples=["Ergonomic 2.4 GHz wireless mouse."])
    price: Price
    inventory_quantity: int = Field(ge=0, examples=[120])
