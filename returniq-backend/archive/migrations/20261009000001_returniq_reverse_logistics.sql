-- ==============================================================================
-- ReturnIQ Core Schema: Reverse Logistics, Recovery & Supplier Quality
-- Event: CYPHER 2026 Hackathon Prototype
-- Migration: 20261009000001_returniq_reverse_logistics.sql
-- Currency: INR (Indian Rupees)
-- Architecture: Server-side mediated (Protected via RLS; Service-Role execution)
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. HELPER TRIGGER FUNCTION FOR UPDATED_AT
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. CORE ENTITIES

-- Table 1: Suppliers / Vendors
CREATE TABLE IF NOT EXISTS public.suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT NOT NULL UNIQUE,
    contact_email TEXT,
    return_window_days INT NOT NULL DEFAULT 30 CHECK (return_window_days > 0),
    credit_agreement_pct NUMERIC(5, 2) NOT NULL DEFAULT 100.00 CHECK (credit_agreement_pct BETWEEN 0 AND 100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 2: Products (Catalog, Demand Velocity & Recovery Parameters)
CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
    sku TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    cost_price_inr NUMERIC(12, 2) NOT NULL CHECK (cost_price_inr >= 0),
    mrp_inr NUMERIC(12, 2) NOT NULL CHECK (mrp_inr >= cost_price_inr),
    current_inventory_units INT NOT NULL DEFAULT 0 CHECK (current_inventory_units >= 0),
    total_units_sold INT NOT NULL DEFAULT 0 CHECK (total_units_sold >= 0),
    daily_demand_velocity NUMERIC(8, 2) NOT NULL DEFAULT 0.00 CHECK (daily_demand_velocity >= 0),
    -- Refurbishment and liquidation economic baselines
    avg_refurb_cost_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (avg_refurb_cost_inr >= 0),
    avg_refurb_days INT NOT NULL DEFAULT 3 CHECK (avg_refurb_days >= 0),
    resale_recovery_pct NUMERIC(5, 2) NOT NULL DEFAULT 70.00 CHECK (resale_recovery_pct BETWEEN 0 AND 100), -- Resale price as % of MRP
    liquidation_rate_pct NUMERIC(5, 2) NOT NULL DEFAULT 20.00 CHECK (liquidation_rate_pct BETWEEN 0 AND 100), -- Clearance price as % of MRP
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 3: Supplier Batches (Inbound Lots for Quality Tracking)
CREATE TABLE IF NOT EXISTS public.supplier_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    batch_code TEXT NOT NULL,
    received_date DATE NOT NULL DEFAULT CURRENT_DATE,
    units_received INT NOT NULL CHECK (units_received > 0),
    defect_alert_threshold_pct NUMERIC(5, 2) NOT NULL DEFAULT 5.00 CHECK (defect_alert_threshold_pct BETWEEN 0 AND 100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_batch UNIQUE (product_id, batch_code)
);

-- Table 4: Returned Inventory (Warehouse Receiving & Reverse Logistics Intake)
CREATE TABLE IF NOT EXISTS public.returned_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES public.supplier_batches(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    return_tracking_id TEXT NOT NULL UNIQUE,
    returned_units INT NOT NULL DEFAULT 1 CHECK (returned_units > 0),
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    return_reason TEXT NOT NULL, -- e.g. 'functional_defect', 'transit_damage', 'missing_accessories', 'customer_remorse', 'wrong_item'
    item_grade VARCHAR(10) NOT NULL CHECK (item_grade IN ('Grade A', 'Grade B', 'Grade C', 'Grade D')),
    status VARCHAR(25) NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'assessed', 'recommendation_ready', 'approved', 'disposed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 5: Recovery Recommendations & Manager Approvals
CREATE TABLE IF NOT EXISTS public.recovery_recommendations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    returned_inventory_id UUID NOT NULL UNIQUE REFERENCES public.returned_inventory(id) ON DELETE CASCADE,
    recommended_route VARCHAR(30) NOT NULL CHECK (recommended_route IN ('return_to_vendor', 'refurbish_and_resell', 'liquidation', 'scrap_recycle')),
    estimated_gross_recovery_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    estimated_cost_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    net_recovery_value_inr NUMERIC(12, 2) GENERATED ALWAYS AS (estimated_gross_recovery_inr - estimated_cost_inr) STORED,
    estimated_turnaround_days INT NOT NULL DEFAULT 0,
    is_rtv_window_active BOOLEAN NOT NULL DEFAULT false,
    recommendation_reasoning TEXT NOT NULL,
    approval_status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected', 'override')),
    approved_by TEXT,
    manager_notes TEXT,
    decided_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 6: Supplier-Batch Quality Alerts
CREATE TABLE IF NOT EXISTS public.supplier_quality_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES public.supplier_batches(id) ON DELETE CASCADE,
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    severity VARCHAR(15) NOT NULL DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'critical')),
    defect_rate_pct NUMERIC(5, 2) NOT NULL,
    threshold_pct NUMERIC(5, 2) NOT NULL,
    total_received INT NOT NULL,
    total_defective INT NOT NULL,
    primary_defect_reason TEXT,
    alert_status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (alert_status IN ('open', 'acknowledged', 'disputed', 'resolved')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

-- 4. TIMESTAMPS TRIGGERS
DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_returned_inventory_updated_at ON public.returned_inventory;
CREATE TRIGGER trg_returned_inventory_updated_at
    BEFORE UPDATE ON public.returned_inventory
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 5. ESSENTIAL INDEXES (Targeted for reverse logistics querying)
CREATE INDEX IF NOT EXISTS idx_products_supplier_id ON public.products(supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_batches_supplier ON public.supplier_batches(supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_batches_product ON public.supplier_batches(product_id);
CREATE INDEX IF NOT EXISTS idx_returned_inventory_batch ON public.returned_inventory(batch_id);
CREATE INDEX IF NOT EXISTS idx_returned_inventory_product ON public.returned_inventory(product_id);
CREATE INDEX IF NOT EXISTS idx_returned_inventory_status ON public.returned_inventory(status);
CREATE INDEX IF NOT EXISTS idx_recovery_recommendations_approval ON public.recovery_recommendations(approval_status);
CREATE INDEX IF NOT EXISTS idx_supplier_quality_alerts_status ON public.supplier_quality_alerts(alert_status);

-- 6. ACCURATE ANALYTICS VIEWS (Strict subquery pre-aggregation to prevent double counting)

-- View 1: Supplier Batch Quality & Vendor Return Window Tracking
CREATE OR REPLACE VIEW public.vw_batch_quality_health AS
SELECT
    b.id AS batch_id,
    b.batch_code,
    s.id AS supplier_id,
    s.name AS supplier_name,
    p.id AS product_id,
    p.name AS product_name,
    p.sku,
    b.received_date,
    b.units_received,
    COALESCE(r.total_returned_units, 0) AS units_returned,
    ROUND(
        (COALESCE(r.total_returned_units, 0)::NUMERIC / b.units_received::NUMERIC) * 100, 
        2
    ) AS return_rate_pct,
    b.defect_alert_threshold_pct,
    (b.received_date + (s.return_window_days * INTERVAL '1 day'))::DATE AS vendor_return_deadline,
    CURRENT_DATE <= (b.received_date + (s.return_window_days * INTERVAL '1 day'))::DATE AS is_rtv_window_active,
    GREATEST(
        0, 
        ((b.received_date + (s.return_window_days * INTERVAL '1 day'))::DATE - CURRENT_DATE)
    ) AS days_remaining_for_rtv,
    ROUND(
        (COALESCE(r.total_returned_units, 0) * p.cost_price_inr * (s.credit_agreement_pct / 100.0)),
        2
    ) AS potential_vendor_credit_inr
FROM public.supplier_batches b
JOIN public.suppliers s ON s.id = b.supplier_id
JOIN public.products p ON p.id = b.product_id
-- Pre-aggregated to prevent Cartesian duplication
LEFT JOIN (
    SELECT batch_id, SUM(returned_units) AS total_returned_units
    FROM public.returned_inventory
    GROUP BY batch_id
) r ON r.batch_id = b.id;

-- View 2: Executive Recovery Pipeline Summary (Financials in INR)
CREATE OR REPLACE VIEW public.vw_inventory_recovery_summary AS
SELECT
    COUNT(rec.id) AS total_recommendations,
    COUNT(CASE WHEN rec.approval_status = 'pending' THEN 1 END) AS pending_approvals_count,
    COUNT(CASE WHEN rec.approval_status = 'approved' THEN 1 END) AS approved_count,
    -- Financial breakdown in INR
    COALESCE(SUM(rec.estimated_gross_recovery_inr), 0) AS total_gross_recovery_inr,
    COALESCE(SUM(rec.estimated_cost_inr), 0) AS total_estimated_costs_inr,
    COALESCE(SUM(rec.net_recovery_value_inr), 0) AS total_net_recovery_inr,
    -- Route distribution
    COUNT(CASE WHEN rec.recommended_route = 'return_to_vendor' THEN 1 END) AS rtv_count,
    COUNT(CASE WHEN rec.recommended_route = 'refurbish_and_resell' THEN 1 END) AS refurbish_count,
    COUNT(CASE WHEN rec.recommended_route = 'liquidation' THEN 1 END) AS liquidation_count,
    COUNT(CASE WHEN rec.recommended_route = 'scrap_recycle' THEN 1 END) AS scrap_count
FROM public.recovery_recommendations rec;

-- View 3: Product Inventory & Velocity Overview
CREATE OR REPLACE VIEW public.vw_product_reverse_logistics AS
SELECT
    p.id AS product_id,
    p.sku,
    p.name AS product_name,
    p.category,
    p.mrp_inr,
    p.cost_price_inr,
    p.current_inventory_units,
    p.total_units_sold,
    COALESCE(ri.total_returned_units, 0) AS total_returned_units,
    CASE
        WHEN p.total_units_sold > 0 THEN
            ROUND((COALESCE(ri.total_returned_units, 0)::NUMERIC / p.total_units_sold::NUMERIC) * 100, 2)
        ELSE 0.00
    END AS return_rate_pct,
    p.daily_demand_velocity,
    CASE
        WHEN p.daily_demand_velocity > 0 THEN
            ROUND((p.current_inventory_units::NUMERIC / p.daily_demand_velocity), 1)
        ELSE NULL
    END AS days_of_inventory_remaining
FROM public.products p
-- Pre-aggregated to prevent Cartesian duplication
LEFT JOIN (
    SELECT product_id, SUM(returned_units) AS total_returned_units
    FROM public.returned_inventory
    GROUP BY product_id
) ri ON ri.product_id = p.id;

-- 7. ROW LEVEL SECURITY (RLS) & ACCESS CONTROL
-- RLS enabled on all tables to lock out unauthorized public/browser access.
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.returned_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recovery_recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_quality_alerts ENABLE ROW LEVEL SECURITY;

-- Note: We intentionally do NOT define broad 'anon' or 'authenticated' USING (true) policies.
-- By default, all anonymous and client-side HTTP requests via Supabase anon key are blocked.
-- Your server-side API (Next.js server actions, Node.js / Express backend) connects using
-- SUPABASE_SERVICE_ROLE_KEY, which bypasses RLS and maintains full, secure control.
