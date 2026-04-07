# ESG Portfolio Intelligence Platform

A distributed data, analytics, and intelligence platform for ESG (Environmental, Social, Governance) portfolio management. Upload a portfolio, enrich assets with ESG and market data, compute risk metrics, detect anomalies, and monitor your holdings through a live dashboard.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        React (TypeScript)                        │
│           Dashboard · Portfolio Upload · Alert Console           │
└────────────────────────────┬────────────────────────────────────┘
                             │ HTTP/REST (Smithy-modeled)
┌────────────────────────────▼────────────────────────────────────┐
│                     Java Backend (Javalin)                       │
│   Portfolio API · Enrichment · Analytics · Snapshot · Alerts    │
│                   Dagger 2 DI · Hexagonal Architecture          │
└──────┬────────────────────────────────────┬─────────────────────┘
       │ JDBC                               │ HTTP
┌──────▼──────────┐               ┌─────────▼──────────┐
│   PostgreSQL    │               │  Python ML Service  │
│  Core storage   │               │  FastAPI + sklearn  │
│  Snapshots      │               │  Anomaly Detection  │
└─────────────────┘               └────────────────────┘
```

**Component responsibilities:**

- **React frontend** — portfolio upload, ESG dashboard, alert management
- **Java backend (Javalin + Dagger 2)** — all business logic, data enrichment, analytics computation, API gateway
- **PostgreSQL** — source of truth for all portfolio, asset, ESG, and metric data
- **Python ML service (FastAPI)** — stateless anomaly detection; called by the Java backend, not directly by the client

---

## Tech Stack

| Layer | Technology                                      |
|---|-------------------------------------------------|
| Frontend | React 18, TypeScript, Recharts                  |
| Backend | Java 21, Javalin 7, Dagger 2                    |
| API Modeling | Smithy                                          |
| ML Service | Python 3.11, FastAPI, scikit-learn              |
| Database | PostgreSQL 16                                   |
| Cache | Redis (post-MVP)                                |
| Build | Gradle (backend), npm/Vite (frontend), pip (ML) |

---

## Project Structure

```
esg-platform/
├── frontend/                  # React TypeScript app
│   ├── src/
│   │   ├── components/
│   │   ├── pages/
│   │   ├── api/               # Generated API client (from Smithy)
│   │   └── hooks/
│   └── package.json
│
├── backend/                   # Java backend
│   ├── src/main/java/com/esg/
│   │   ├── domain/            # Entities, value objects, ports
│   │   │   ├── model/
│   │   │   └── port/          # Inbound + outbound port interfaces
│   │   ├── application/       # Use cases (orchestration only)
│   │   ├── adapter/
│   │   │   ├── inbound/       # Javalin HTTP handlers
│   │   │   ├── outbound/      # PostgreSQL repos, ML client, enrichment client
│   │   │   └── di/            # Dagger component + modules
│   │   └── Main.java
│   └── build.gradle
│
├── ml-service/                # Python anomaly detection service
│   ├── app/
│   │   ├── main.py            # FastAPI app
│   │   ├── models/            # sklearn model wrappers
│   │   ├── schemas.py         # Pydantic request/response models
│   │   └── detector.py        # Anomaly detection logic
│   └── requirements.txt
│
├── model/                     # Smithy API models
│   └── src/main/smithy/
│       ├── portfolio.smithy
│       ├── asset.smithy
│       └── analytics.smithy
│
├── db/
│   └── migrations/            # Flyway SQL migrations
│
└── docker-compose.yml
```

---

## Getting Started

### Prerequisites

- Java 21+
- Python 3.11+
- Node.js 20+
- PostgreSQL 16 (or Docker)

### 1. Start infrastructure

```bash
docker-compose up -d postgres
```

### 2. Run database migrations

```bash
cd backend
./gradlew flywayMigrate
```

### 3. Start the ML service

```bash
cd ml-service
pip install -r requirements.txt
uvicorn app.main:app --port 8001 --reload
```

### 4. Start the Java backend

```bash
cd backend
./gradlew run
# Starts on port 8080
```

### 5. Start the React frontend

```bash
cd frontend
npm install
npm run dev
# Opens on http://localhost:5173
```

---

## API

APIs are modeled in Smithy under `model/`. The Java backend exposes REST endpoints.

Key API surface:

| Method | Path | Description |
|---|---|---|
| POST | /portfolios | Create a portfolio |
| POST | /portfolios/{id}/holdings | Upload holdings |
| POST | /portfolios/{id}/enrich | Trigger ESG + market data enrichment |
| GET | /portfolios/{id}/metrics | Get computed ESG + risk metrics |
| GET | /portfolios/{id}/snapshots | Get historical metric snapshots |
| GET | /portfolios/{id}/alerts | Get active alerts |
| POST | /portfolios/{id}/anomaly-check | Run anomaly detection |

---

## Design Principles

- **Hexagonal architecture** — all business logic lives in `domain/` and `application/`. HTTP and database are adapters.
- **Ports and adapters** — the domain defines interfaces (`ports`); adapters implement them. The domain never imports Javalin, JDBC, or HTTP client libraries.
- **Dagger 2 for DI** — no Spring, no magic. All wiring is explicit and compile-time verified.
- **Smithy-first API design** — API shapes are defined in Smithy before implementation.
- **Correctness before scale** — idempotency keys on enrichment and snapshot jobs; no optimistic locking for MVP.
- **ML service is a sidecar** — the Python service is stateless and called synchronously by the Java backend. It holds no persistent state.

---

## MVP Scope

See [MVP_SCOPE.md](./MVP_SCOPE.md) for a detailed breakdown of what is and is not in scope for the MVP.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The architecture decision log lives in `docs/adr/`.