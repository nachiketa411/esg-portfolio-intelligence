# MVP Scope — ESG Portfolio Intelligence Platform

This document defines the precise boundary of the MVP. Everything in "In Scope" must work end-to-end before any "Post-MVP" item is considered. The goal is a functioning system that proves the core loop — not a feature-complete product.

---

## The Core MVP Loop

```
Upload Portfolio → Enrich with ESG Data → Compute Metrics → Store Snapshot → Display Dashboard → Detect Anomalies → Fire Alert
```

Every feature that is not on this critical path is post-MVP.

---

## In Scope

### 1. Portfolio Management
- Create a named portfolio with an owner identifier (no auth yet — owner is a plain string field)
- Upload holdings as a CSV or JSON list of (ticker, asset_class, weight)
- Validate: weights sum to ~1.0 (±0.01 tolerance), no duplicate tickers, non-negative weights
- Store portfolio + holdings in PostgreSQL
- Retrieve portfolio with current holdings

### 2. ESG Data Enrichment
- For each holding, fetch ESG scores (E, S, G sub-scores + composite) from a stubbed external data provider
    - MVP: use a mock/stub enrichment adapter that returns deterministic fake scores based on ticker; swap for real provider later
- Store enriched ESG scores per asset in the database
- Enrichment is triggered explicitly via API (not automatic on upload)
- Idempotency: re-enriching the same portfolio at the same time is safe (upsert on ticker + enrichment_date)

### 3. Portfolio Metric Computation
- Compute portfolio-level weighted ESG scores (weighted average across holdings)
- Compute basic risk metrics:
    - Portfolio ESG composite score (weighted)
    - ESG score volatility (std dev across holdings)
    - Concentration risk: max single holding weight
    - Carbon intensity score (mocked per asset; weighted at portfolio level)
- Store computed metrics as an immutable snapshot (timestamp + metric values)
- Recomputing for the same portfolio at the same timestamp is idempotent

### 4. Historical Snapshots
- Store one snapshot per enrichment run (time-series of portfolio health)
- Retrieve snapshot history for a portfolio (ordered by timestamp)
- No deletion or amendment of snapshots (append-only)

### 5. Anomaly Detection (ML Service)
- Python FastAPI service accepts a portfolio's metric history (array of snapshots)
- Runs Isolation Forest (scikit-learn) to detect anomalous snapshots
- Returns: list of snapshot IDs flagged as anomalous + anomaly scores
- Stateless: no model persistence for MVP (model is fit on-the-fly per request)
- The Java backend calls the ML service after each enrichment + metric computation run

### 6. Alerts
- Threshold-based alerts: if portfolio composite ESG score drops below a configurable threshold, create an alert
- Alerts are created by the Java backend (not the ML service) based on metric values
- Alert states: OPEN, ACKNOWLEDGED
- Retrieve active alerts for a portfolio

### 7. Dashboard (React)
- Portfolio overview: name, total holdings count, last enrichment date
- Current ESG metrics: E/S/G breakdown (bar or gauge chart)
- Historical ESG composite score (line chart over snapshots)
- Active alerts panel
- Anomaly flags on the snapshot timeline (visual marker)

---

## Out of Scope (Post-MVP)

| Feature | Reason deferred |
|---|---|
| Authentication / multi-tenancy | Adds significant complexity; owner is a plain string for MVP |
| Real ESG data provider integration (MSCI, Sustainalytics) | Requires paid API keys and contract; mock is sufficient to prove the system |
| Async enrichment pipeline (queues, workers) | Synchronous enrichment is sufficient for MVP portfolios (<100 holdings) |
| Redis caching | No performance problem to solve at MVP scale |
| Portfolio versioning / holdings history | Only current holdings matter for MVP |
| ML model persistence + retraining pipeline | On-the-fly model fitting is acceptable for MVP volume |
| Alert notification delivery (email, Slack) | Alerts exist in the DB; notification delivery is post-MVP |
| Benchmark comparison (portfolio vs index) | No index data feed available |
| PDF report generation | Nice-to-have; not on critical path |
| Role-based access control | No auth at all for MVP |
| Audit logging | Post-MVP; schema is designed to accommodate it |
| Kubernetes / container orchestration | Docker Compose is sufficient for MVP |

---

## Mock Strategy

The MVP uses stubs aggressively for external dependencies so the core loop can be tested end-to-end without real data contracts.

| Dependency | MVP approach |
|---|---|
| ESG data provider | `MockEsgEnrichmentAdapter` — returns deterministic scores by ticker hash |
| Market data (prices, volatility) | Hardcoded fixture values per asset class |
| Carbon intensity data | Randomly seeded but deterministic per ticker |
| ML model training data | Isolation Forest fit on whatever snapshots are available; no minimum size check for MVP |

All mock adapters implement the same port interfaces as production adapters. Swapping them requires only a Dagger module change — zero business logic changes.

---

## Definition of Done

The MVP is complete when all of the following can be demonstrated end-to-end:

1. A portfolio with ≥5 holdings can be uploaded via the React UI
2. Enrichment can be triggered and ESG scores appear in the database
3. Metrics are computed and a snapshot is stored
4. The React dashboard shows current ESG metrics and a historical chart with ≥2 snapshots
5. The Python ML service is called and returns an anomaly result
6. If the portfolio ESG score is below threshold, an alert appears in the UI
7. The Java backend starts cleanly with `./gradlew run` and the ML service starts with `uvicorn`
8. All core entities have Flyway migrations applied successfully on a fresh PostgreSQL instance

---

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Isolation Forest returns noisy results with few snapshots | High | Document minimum snapshot count (≥10) in UI; show "insufficient data" message below threshold |
| Weight validation is too strict for real-world data (rounding errors) | Medium | Use ±0.01 tolerance; log validation warnings, don't hard-fail |
| Smithy code generation adds toolchain friction | Medium | Hand-write the initial API surface first; add Smithy generation in a follow-up |
| PostgreSQL timestamp precision causes duplicate snapshot detection to fail | Low | Store timestamps at millisecond precision; use (portfolio_id, computed_at) composite unique index |