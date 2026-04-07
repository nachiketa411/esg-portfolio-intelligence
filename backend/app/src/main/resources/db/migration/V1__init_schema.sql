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