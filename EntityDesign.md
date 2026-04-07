# Core Entity Design — ESG Portfolio Intelligence Platform

This document defines the core domain entities, their relationships, and the PostgreSQL schema for the MVP. All entities follow a hexagonal architecture pattern: the domain model is pure Java (no framework annotations), and the persistence layer is a separate adapter.

---

## 1. Functional Requirements (this task)

- Represent a portfolio and its constituent holdings
- Store ESG scores per asset (enriched from an external provider)
- Store computed portfolio-level metrics as immutable snapshots
- Store threshold-based alerts
- Support anomaly detection results attached to snapshots

## 2. Non-Functional Requirements (MVP)

- Correctness: no metric snapshot is silently overwritten; snapshots are append-only
- Idempotency: upserting ESG scores for the same ticker + date is safe
- Auditability: all rows carry created_at; snapshots carry computed_at
- Simplicity: no soft deletes, no row-level versioning, no JSONB blobs for MVP

---

## 3. Core Entities

### Entity Relationship Summary

```
Portfolio (1) ──── (N) Holding
Holding   (N) ──── (1) Asset
Asset     (1) ──── (N) EsgScore        [one per enrichment date]
Portfolio (1) ──── (N) MetricSnapshot  [one per enrichment run]
MetricSnapshot (1) ──── (0..1) AnomalyResult
Portfolio (1) ──── (N) Alert
```

### Entity Definitions

#### Portfolio
The top-level aggregate root. Owns the set of holdings at a point in time.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key, generated |
| name | String | Human-readable name, unique per owner |
| owner | String | Plain string for MVP (no auth); user identifier |
| status | Enum | DRAFT, ACTIVE, ARCHIVED |
| created_at | Timestamp | Immutable |
| updated_at | Timestamp | Updated on any mutation |

**Invariants:**
- A portfolio in ACTIVE status must have at least one holding
- Holdings must sum to 1.0 (±0.01 tolerance) before a portfolio can be enriched

#### Holding
A position within a portfolio — one row per (portfolio, ticker) pair.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| portfolio_id | UUID | FK → Portfolio |
| asset_id | UUID | FK → Asset |
| weight | Decimal | 0.0–1.0; sum across portfolio must ≈ 1.0 |
| created_at | Timestamp | Immutable |

**Invariants:**
- No duplicate (portfolio_id, asset_id) pairs
- weight ∈ (0, 1]

#### Asset
A financial instrument. Shared across portfolios. Normalized to avoid duplicating ESG scores per portfolio.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| ticker | String | Unique; e.g. "AAPL", "MSFT" |
| name | String | Human-readable name |
| asset_class | Enum | EQUITY, BOND, COMMODITY, ETF, CASH |
| sector | String | GICS sector string; nullable for MVP |
| created_at | Timestamp | Immutable |

**Design note:** Asset is a shared reference entity, not owned by any portfolio. This allows ESG scores to be computed once and reused across portfolios holding the same ticker.

#### EsgScore
Enriched ESG data for an asset at a specific date. Append-only: a new row per enrichment date, not an update to existing.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| asset_id | UUID | FK → Asset |
| enrichment_date | Date | The date the score was fetched for |
| environmental_score | Decimal | 0.0–100.0 |
| social_score | Decimal | 0.0–100.0 |
| governance_score | Decimal | 0.0–100.0 |
| composite_score | Decimal | Weighted average of E/S/G; computed by provider |
| carbon_intensity | Decimal | tCO2e per $M revenue; nullable |
| provider | String | "MOCK" for MVP; e.g. "MSCI" in production |
| created_at | Timestamp | Immutable |

**Unique constraint:** (asset_id, enrichment_date, provider) — prevents duplicate enrichment for the same asset/date/source.

**Idempotency:** Upsert on the unique constraint — if a record already exists, do not overwrite; return existing. This makes enrichment retries safe.

#### MetricSnapshot
Computed portfolio-level metrics at a point in time. Immutable once written.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| portfolio_id | UUID | FK → Portfolio |
| computed_at | Timestamp | When metrics were computed (millisecond precision) |
| weighted_esg_composite | Decimal | Weighted avg composite ESG across holdings |
| weighted_environmental | Decimal | Weighted avg E score |
| weighted_social | Decimal | Weighted avg S score |
| weighted_governance | Decimal | Weighted avg G score |
| esg_score_volatility | Decimal | Std dev of composite ESG scores across holdings |
| max_holding_weight | Decimal | Largest single holding weight (concentration risk) |
| weighted_carbon_intensity | Decimal | Weighted avg carbon intensity; nullable |
| holding_count | Integer | Number of holdings at compute time |
| created_at | Timestamp | Immutable |

**Unique constraint:** (portfolio_id, computed_at) — prevents two snapshots at the exact same millisecond (concurrent compute guard).

**Design note:** Metrics are denormalized into flat columns (not JSONB) for MVP. This enables simple SQL queries for the time-series chart without JSON parsing. Post-MVP, a JSONB `extended_metrics` column can be added for custom/provider-specific metrics without a schema migration.

#### AnomalyResult
The output of the ML service for a given snapshot. One result per snapshot, written after the ML call completes.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| snapshot_id | UUID | FK → MetricSnapshot, unique |
| is_anomalous | Boolean | True if Isolation Forest flagged this snapshot |
| anomaly_score | Decimal | Raw score from sklearn (-1 to 1 range normalized to 0–1) |
| model_version | String | Version/params of the model used; "IsolationForest-v1" for MVP |
| detected_at | Timestamp | When the ML call completed |

**Design note:** AnomalyResult is a separate table (not a column on MetricSnapshot) so that anomaly detection can be added asynchronously post-MVP without altering the snapshot table.

#### Alert
A threshold violation detected by the Java backend during metric computation.

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| portfolio_id | UUID | FK → Portfolio |
| snapshot_id | UUID | FK → MetricSnapshot; the snapshot that triggered this |
| alert_type | Enum | ESG_SCORE_BELOW_THRESHOLD, ANOMALY_DETECTED, CONCENTRATION_RISK |
| severity | Enum | LOW, MEDIUM, HIGH |
| message | String | Human-readable description |
| threshold_value | Decimal | The configured threshold that was breached; nullable |
| observed_value | Decimal | The actual metric value that breached; nullable |
| status | Enum | OPEN, ACKNOWLEDGED |
| created_at | Timestamp | Immutable |
| acknowledged_at | Timestamp | Nullable; set when status → ACKNOWLEDGED |

---

## 4. API (Smithy sketch)

```smithy
// portfolio.smithy
namespace com.esg.portfolio

resource Portfolio {
    identifiers: { portfolioId: PortfolioId }
    create: CreatePortfolio
    read: GetPortfolio
}

@http(method: "POST", uri: "/portfolios")
operation CreatePortfolio {
    input: CreatePortfolioInput
    output: CreatePortfolioOutput
}

structure CreatePortfolioInput {
    @required name: String
    @required owner: String
}

structure CreatePortfolioOutput {
    @required portfolioId: PortfolioId
    @required status: PortfolioStatus
}

@http(method: "POST", uri: "/portfolios/{portfolioId}/holdings")
operation UploadHoldings {
    input: UploadHoldingsInput
    output: UploadHoldingsOutput
    errors: [ValidationError, PortfolioNotFound]
}

@http(method: "POST", uri: "/portfolios/{portfolioId}/enrich")
operation EnrichPortfolio {
    input: EnrichPortfolioInput
    output: EnrichPortfolioOutput
}

@http(method: "GET", uri: "/portfolios/{portfolioId}/metrics")
operation GetPortfolioMetrics {
    input: GetPortfolioMetricsInput
    output: GetPortfolioMetricsOutput
}

@http(method: "GET", uri: "/portfolios/{portfolioId}/snapshots")
operation ListSnapshots {
    input: ListSnapshotsInput
    output: ListSnapshotsOutput
}
```

---

## 5. High-Level Design (Entity Layer)

```
┌──────────────────────────────────────────────────────────┐
│                     Domain Layer                          │
│                                                          │
│  Portfolio ──owns──► Holding ──refs──► Asset             │
│                                            │              │
│                                       EsgScore           │
│                                                          │
│  Portfolio ──has──► MetricSnapshot ──has──► AnomalyResult│
│  Portfolio ──has──► Alert                                │
└──────────────────────────────────────────────────────────┘
```

**Aggregate boundaries:**
- `Portfolio` is the aggregate root for portfolio + holdings. Holding IDs are only meaningful within a portfolio context.
- `Asset` + `EsgScore` form their own aggregate. Multiple portfolios share the same Asset records.
- `MetricSnapshot` + `AnomalyResult` form a snapshot aggregate. A snapshot is immutable; its anomaly result is written once.
- `Alert` is a separate aggregate — it references a portfolio and snapshot but has its own lifecycle (OPEN → ACKNOWLEDGED).

---

## 6. PostgreSQL DDL

```sql
-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────
-- Portfolio
-- ─────────────────────────────────────────────
CREATE TYPE portfolio_status AS ENUM ('DRAFT', 'ACTIVE', 'ARCHIVED');

CREATE TABLE portfolios (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         VARCHAR(255) NOT NULL,
    owner        VARCHAR(255) NOT NULL,
    status       portfolio_status NOT NULL DEFAULT 'DRAFT',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (owner, name)
);

-- ─────────────────────────────────────────────
-- Asset
-- ─────────────────────────────────────────────
CREATE TYPE asset_class AS ENUM ('EQUITY', 'BOND', 'COMMODITY', 'ETF', 'CASH');

CREATE TABLE assets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker       VARCHAR(20) NOT NULL UNIQUE,
    name         VARCHAR(255) NOT NULL,
    asset_class  asset_class NOT NULL,
    sector       VARCHAR(100),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- Holding
-- ─────────────────────────────────────────────
CREATE TABLE holdings (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
    asset_id     UUID NOT NULL REFERENCES assets(id),
    weight       NUMERIC(10, 6) NOT NULL CHECK (weight > 0 AND weight <= 1),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (portfolio_id, asset_id)
);

-- ─────────────────────────────────────────────
-- ESG Score
-- ─────────────────────────────────────────────
CREATE TABLE esg_scores (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id             UUID NOT NULL REFERENCES assets(id),
    enrichment_date      DATE NOT NULL,
    environmental_score  NUMERIC(6, 2) NOT NULL CHECK (environmental_score BETWEEN 0 AND 100),
    social_score         NUMERIC(6, 2) NOT NULL CHECK (social_score BETWEEN 0 AND 100),
    governance_score     NUMERIC(6, 2) NOT NULL CHECK (governance_score BETWEEN 0 AND 100),
    composite_score      NUMERIC(6, 2) NOT NULL CHECK (composite_score BETWEEN 0 AND 100),
    carbon_intensity     NUMERIC(12, 4),  -- tCO2e per $M revenue
    provider             VARCHAR(50) NOT NULL DEFAULT 'MOCK',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (asset_id, enrichment_date, provider)
);

-- ─────────────────────────────────────────────
-- Metric Snapshot
-- ─────────────────────────────────────────────
CREATE TABLE metric_snapshots (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id             UUID NOT NULL REFERENCES portfolios(id),
    computed_at              TIMESTAMPTZ NOT NULL,
    weighted_esg_composite   NUMERIC(6, 2) NOT NULL,
    weighted_environmental   NUMERIC(6, 2) NOT NULL,
    weighted_social          NUMERIC(6, 2) NOT NULL,
    weighted_governance      NUMERIC(6, 2) NOT NULL,
    esg_score_volatility     NUMERIC(8, 4) NOT NULL,
    max_holding_weight       NUMERIC(8, 6) NOT NULL,
    weighted_carbon_intensity NUMERIC(12, 4),
    holding_count            INTEGER NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (portfolio_id, computed_at)
);

-- ─────────────────────────────────────────────
-- Anomaly Result
-- ─────────────────────────────────────────────
CREATE TABLE anomaly_results (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id    UUID NOT NULL UNIQUE REFERENCES metric_snapshots(id),
    is_anomalous   BOOLEAN NOT NULL,
    anomaly_score  NUMERIC(8, 6) NOT NULL,
    model_version  VARCHAR(100) NOT NULL DEFAULT 'IsolationForest-v1',
    detected_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- Alert
-- ─────────────────────────────────────────────
CREATE TYPE alert_type AS ENUM (
    'ESG_SCORE_BELOW_THRESHOLD',
    'ANOMALY_DETECTED',
    'CONCENTRATION_RISK'
);

CREATE TYPE alert_severity AS ENUM ('LOW', 'MEDIUM', 'HIGH');
CREATE TYPE alert_status AS ENUM ('OPEN', 'ACKNOWLEDGED');

CREATE TABLE alerts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id     UUID NOT NULL REFERENCES portfolios(id),
    snapshot_id      UUID NOT NULL REFERENCES metric_snapshots(id),
    alert_type       alert_type NOT NULL,
    severity         alert_severity NOT NULL,
    message          TEXT NOT NULL,
    threshold_value  NUMERIC(10, 4),
    observed_value   NUMERIC(10, 4),
    status           alert_status NOT NULL DEFAULT 'OPEN',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    acknowledged_at  TIMESTAMPTZ
);

-- ─────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────
CREATE INDEX idx_holdings_portfolio_id ON holdings(portfolio_id);
CREATE INDEX idx_esg_scores_asset_date ON esg_scores(asset_id, enrichment_date DESC);
CREATE INDEX idx_metric_snapshots_portfolio_computed ON metric_snapshots(portfolio_id, computed_at DESC);
CREATE INDEX idx_alerts_portfolio_status ON alerts(portfolio_id, status);
```

---

## 7. Java Domain Model (Hexagonal Layer)

```java
// domain/model/Portfolio.java
public record Portfolio(
    PortfolioId id,
    String name,
    String owner,
    PortfolioStatus status,
    Instant createdAt,
    Instant updatedAt
) {
    public boolean canBeEnriched() {
        return status == PortfolioStatus.ACTIVE;
    }
}

// domain/model/Holding.java
public record Holding(
    HoldingId id,
    PortfolioId portfolioId,
    AssetId assetId,
    BigDecimal weight,
    Instant createdAt
) {}

// domain/model/Asset.java
public record Asset(
    AssetId id,
    String ticker,
    String name,
    AssetClass assetClass,
    String sector,
    Instant createdAt
) {}

// domain/model/EsgScore.java
public record EsgScore(
    EsgScoreId id,
    AssetId assetId,
    LocalDate enrichmentDate,
    BigDecimal environmentalScore,
    BigDecimal socialScore,
    BigDecimal governanceScore,
    BigDecimal compositeScore,
    BigDecimal carbonIntensity,  // nullable
    String provider,
    Instant createdAt
) {}

// domain/model/MetricSnapshot.java
public record MetricSnapshot(
    SnapshotId id,
    PortfolioId portfolioId,
    Instant computedAt,
    BigDecimal weightedEsgComposite,
    BigDecimal weightedEnvironmental,
    BigDecimal weightedSocial,
    BigDecimal weightedGovernance,
    BigDecimal esgScoreVolatility,
    BigDecimal maxHoldingWeight,
    BigDecimal weightedCarbonIntensity,  // nullable
    int holdingCount,
    Instant createdAt
) {}

// domain/model/AnomalyResult.java
public record AnomalyResult(
    AnomalyResultId id,
    SnapshotId snapshotId,
    boolean isAnomalous,
    BigDecimal anomalyScore,
    String modelVersion,
    Instant detectedAt
) {}

// domain/model/Alert.java
public record Alert(
    AlertId id,
    PortfolioId portfolioId,
    SnapshotId snapshotId,
    AlertType alertType,
    AlertSeverity severity,
    String message,
    BigDecimal thresholdValue,  // nullable
    BigDecimal observedValue,   // nullable
    AlertStatus status,
    Instant createdAt,
    Instant acknowledgedAt      // nullable
) {
    public Alert acknowledge() {
        return new Alert(id, portfolioId, snapshotId, alertType, severity,
            message, thresholdValue, observedValue,
            AlertStatus.ACKNOWLEDGED, createdAt, Instant.now());
    }
}

// domain/port/outbound/PortfolioRepository.java
public interface PortfolioRepository {
    Portfolio save(Portfolio portfolio);
    Optional<Portfolio> findById(PortfolioId id);
    List<Holding> findHoldingsByPortfolioId(PortfolioId portfolioId);
    void saveHoldings(PortfolioId portfolioId, List<Holding> holdings);
}

// domain/port/outbound/EsgEnrichmentPort.java
public interface EsgEnrichmentPort {
    List<EsgScore> fetchScores(List<String> tickers, LocalDate date);
}

// domain/port/outbound/MetricSnapshotRepository.java
public interface MetricSnapshotRepository {
    MetricSnapshot save(MetricSnapshot snapshot);
    List<MetricSnapshot> findByPortfolioId(PortfolioId portfolioId);
}

// domain/port/outbound/AnomalyDetectionPort.java
public interface AnomalyDetectionPort {
    List<AnomalyResult> detect(List<MetricSnapshot> snapshots);
}
```

---

## 8. Trade-offs

**Flat metric columns vs JSONB:** Flat columns make the time-series query trivial (`SELECT computed_at, weighted_esg_composite FROM metric_snapshots WHERE portfolio_id = ? ORDER BY computed_at`). JSONB would require `->>'weighted_esg_composite'` and loses index support. Post-MVP, a `JSONB extended_metrics` column can hold provider-specific or custom metrics without touching the core columns.

**Asset as a shared entity vs embedding per holding:** Normalizing Asset means ESG scores are computed once and stored once per ticker/date, regardless of how many portfolios hold that asset. The alternative — storing ESG scores per holding — would duplicate data massively and make cache invalidation (post-MVP) harder. The tradeoff is a slightly more complex join at query time, which is acceptable.

**AnomalyResult as a separate table vs a column on MetricSnapshot:** A separate table allows the anomaly detection to be made asynchronous post-MVP (write snapshot, queue the ML call, write result later) without changing the snapshot table schema. For MVP the call is synchronous, but the schema is already async-ready.

**Snapshots are immutable:** Metric snapshots are never updated. Re-enriching a portfolio creates a new snapshot. This makes the time-series chart trivially correct and eliminates the possibility of metric drift (where recomputed values silently change historical records). The cost is that storage grows with each enrichment run — acceptable at MVP scale.

**No soft deletes for MVP:** Holding deletes (when a portfolio is re-uploaded) use hard deletes within a transaction. The `CASCADE` on `portfolio_id` handles holding cleanup. If audit history of holding changes becomes a requirement post-MVP, it can be added via a `holding_history` table without touching the current schema.