# ecommerce-api

A small, stateless FastAPI product-catalogue service. It is the workload for the
AWS infrastructure in this repository:

```
Internet -> CloudFront -> ALB -> EC2 Auto Scaling group -> Docker container (this app)
```

The application is intentionally simple; the focus of the project is the
platform around it.

## Technology stack

| Concern        | Choice                                      |
|----------------|---------------------------------------------|
| Language       | Python 3.12+ (image uses Python 3.13)       |
| Web framework  | FastAPI, served by Uvicorn                  |
| Validation     | Pydantic v2                                 |
| Tests          | pytest + HTTPX (FastAPI `TestClient`)       |
| Packaging      | Docker, `python:3.13-slim`, non-root user   |

## Project layout

```
app/
├── main.py                 # FastAPI app factory and logging setup
├── config.py               # Settings read from environment variables
├── dependencies.py         # Dependency-injection providers
├── api/                    # HTTP layer (routes only)
│   ├── system.py           #   GET /, GET /health
│   └── products.py         #   GET /api/products, GET /api/products/{id}
├── services/               # Business logic
│   └── product_service.py
├── repositories/           # Data access behind an interface
│   ├── base.py             #   ProductRepository (abstract)
│   └── in_memory.py        #   Read-only sample data
├── models/                 # Pydantic schemas
│   ├── product.py
│   └── system.py
├── tests/test_api.py
├── requirements.txt        # Runtime dependencies (in the image)
├── requirements-dev.txt    # + test dependencies (not in the image)
├── pytest.ini
├── Dockerfile
└── .dockerignore
```

Requests flow `api -> services -> repositories`. Routes get a `ProductService`
through `Depends()`, and the service only knows the `ProductRepository`
interface, so storage can be swapped without touching routes or business logic.

## Local setup

All commands run from the `app/` directory. Dependencies go into a local
virtual environment (ignored by git), never into the global Python.

```bash
cd app
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
```

## Run with Uvicorn

```bash
uvicorn main:app --reload --port 8080
```

Then open <http://localhost:8080/docs>.

## Run the tests

```bash
pytest
```

The tests use FastAPI's in-process `TestClient`; they need no AWS account,
Docker or database.

## Docker

From the repository root:

```bash
docker build -t ecommerce-api ./app
docker run --rm -p 8080:8080 ecommerce-api
```

- <http://localhost:8080/health>
- <http://localhost:8080/api/products>
- <http://localhost:8080/docs>

The container runs as an unprivileged user (`app`, UID 10001), listens on
`0.0.0.0:8080`, and logs to stdout/stderr. Uvicorn is PID 1 (exec-form `CMD`),
so `docker stop` (SIGTERM) lets in-flight requests finish before it exits.

## Configuration

| Variable                      | Default         | Purpose                                   |
|-------------------------------|-----------------|-------------------------------------------|
| `APP_NAME`                    | `ecommerce-api` | Name shown by `GET /` and in the docs     |
| `APP_VERSION`                 | `0.1.0`         | Version shown by `GET /` (e.g. a git SHA) |
| `APP_ENV`                     | `local`         | `local`, `dev` or `prod`                  |
| `LOG_LEVEL`                   | `INFO`          | Python logging level                      |
| `UVICORN_PORT`                | `8080`          | Listening port (Docker image)             |
| `UVICORN_HOST`                | `0.0.0.0`       | Bind address (Docker image)               |
| `UVICORN_FORWARDED_ALLOW_IPS` | `127.0.0.1,::1` | Proxies whose `X-Forwarded-*` headers are trusted (IPs or CIDRs) |

Uvicorn reads any `UVICORN_*` variable as the matching CLI option, for example:

```bash
docker run --rm -p 9000:9000 -e UVICORN_PORT=9000 -e APP_ENV=dev ecommerce-api
```

No credentials, secrets or AWS resource identifiers are stored in the code or
the image.

## API endpoints

| Method | Path                         | Description                                         |
|--------|------------------------------|-----------------------------------------------------|
| GET    | `/`                          | Application name, version and environment           |
| GET    | `/health`                    | `{"status": "healthy"}`; ALB target group health check |
| GET    | `/api/products`              | All products                                        |
| GET    | `/api/products/{product_id}` | One product; `404` if missing, `422` if the ID is invalid |
| GET    | `/docs`                      | Interactive OpenAPI documentation (Swagger UI)      |

A product looks like:

```json
{
  "id": 1,
  "name": "Wireless Mouse",
  "description": "Ergonomic 2.4 GHz wireless mouse with a USB-C receiver.",
  "price": 24.99,
  "inventory_quantity": 150
}
```

`/health` checks only that the process is serving requests. It deliberately
does not check the database: if it did, a database outage would mark every
instance unhealthy at once and the Auto Scaling group would replace them in a
loop without fixing anything.

## Running on AWS

- The app is stateless (no sessions, carts or local files), so any instance can
  serve any request behind the ALB.
- It needs no internet access at startup; everything is baked into the image.
- Logs go to stdout/stderr for the Docker log driver / CloudWatch agent.
- The infrastructure's `AppContainerPort` parameter (security groups, ALB
  target group) is `8080`, matching the image default. If it ever changes, run
  the container with `-e UVICORN_PORT=<AppContainerPort>`. The ALB listener
  port (80/443) is separate and unaffected.

### Trusted proxies (`X-Forwarded-*`)

The ALB adds `X-Forwarded-For` (client IP) and `X-Forwarded-Proto` (`http` or
`https`). Uvicorn honours these headers only when the TCP connection comes from
an address in `UVICORN_FORWARDED_ALLOW_IPS`; from anyone else they are ignored,
so a client cannot fake its IP or scheme.

| Where | Value | Why |
|-------|-------|-----|
| Local / Docker (default) | `127.0.0.1,::1` | Nothing is in front of the app; headers from clients are ignored |
| EC2 behind the ALB | the VPC CIDR, e.g. `10.10.0.0/16` (dev), `10.20.0.0/16` (prod) | ALB nodes connect from private IPs in the public subnets, and those IPs change as the ALB scales |

Do not use `*` on AWS. The app security group already admits only the ALB
security group on `AppContainerPort`, so nothing else in the VPC can reach the
container; trusting the VPC CIDR keeps a second, independent limit in the app
in case a security group rule is ever widened.

Behind CloudFront, the ALB is the last hop, so `request.client` becomes the
CloudFront edge address, not the viewer. If the viewer IP is needed, read
CloudFront's `CloudFront-Viewer-Address` header (enabled in the origin request
policy); don't trust CloudFront's IP ranges here.

## Future: Amazon RDS PostgreSQL

The repository layer is ready for a database-backed implementation:

1. Add `sqlalchemy` and `psycopg[binary]` to `requirements.txt`.
2. Implement `repositories/postgres.py` with a `PostgresProductRepository`
   that subclasses `ProductRepository`, mapping rows with
   `Product.model_validate(row)` (the model has `from_attributes=True`; `price`
   is a `Decimal` that maps to `NUMERIC(10, 2)`).
3. Add database settings to `config.py` (host, port, name), read from
   environment variables, with the credentials fetched from the RDS-managed
   Secrets Manager secret at startup, never stored in the image.
4. Return the new repository from `get_product_repository()` in
   `dependencies.py`. Routes, services and tests stay unchanged.
5. Keep `/health` free of database checks; add a separate readiness endpoint
   if a database check is wanted.
