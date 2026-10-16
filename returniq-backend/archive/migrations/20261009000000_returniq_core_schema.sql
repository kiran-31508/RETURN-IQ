-- ==============================================================================
-- ReturnIQ Core Schema: Hackathon Prototype Foundation
-- Migration: 20261009000000_returniq_core_schema.sql
-- Description: Core tables, enums, indexes, analytics views, and RLS policies
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. CUSTOM ENUM TYPES
DO $$ BEGIN
    CREATE TYPE return_status AS ENUM (
        'requested',
        'approved',
        'rejected',
        'received',
        'inspected',
        'completed',
        'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE return_reason_category AS ENUM (
        'size_fit',
        'quality_defect',
        'not_as_described',
        'arrived_late',
        'buyer_remorse',
        'damaged_in_transit',
        'wrong_item_sent',
        'other'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE item_condition AS ENUM (
        'unopened',
        'opened_like_new',
        'damaged',
        'defective',
        'used'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE disposition_action AS ENUM (
        'pending_inspection',
        'restock',
        'refurbish',
        'liquidate',
        'recycle',
        'destroy'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE risk_level AS ENUM (
        'low',
        'medium',
        'high',
        'critical'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 3. HELPER TRIGGER FUNCTION FOR UPDATED_AT
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. CORE TABLES

-- Stores / Merchants
CREATE TABLE IF NOT EXISTS public.stores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    domain TEXT,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',
    return_window_days INT NOT NULL DEFAULT 30,
    auto_approve_low_risk BOOLEAN NOT NULL DEFAULT true,
    risk_threshold_score INT NOT NULL DEFAULT 60,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Catalog Products
CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    sku TEXT NOT NULL,
    title TEXT NOT NULL,
    category TEXT,
    retail_price NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    unit_cost NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_products_store_sku UNIQUE (store_id, sku)
);

-- Orders
CREATE TABLE IF NOT EXISTS public.orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    order_number TEXT NOT NULL,
    customer_email TEXT NOT NULL,
    customer_name TEXT,
    order_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    total_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_orders_store_order_number UNIQUE (store_id, order_number)
);

-- Order Items
CREATE TABLE IF NOT EXISTS public.order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Returns (Return Cases / Requests)
CREATE TABLE IF NOT EXISTS public.returns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    return_number TEXT NOT NULL UNIQUE,
    status return_status NOT NULL DEFAULT 'requested',
    risk_score INT NOT NULL DEFAULT 0 CHECK (risk_score BETWEEN 0 AND 100),
    risk_tier risk_level NOT NULL DEFAULT 'low',
    risk_signals JSONB NOT NULL DEFAULT '[]'::jsonb,
    estimated_refund_total NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    merchant_notes TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Return Items (Line items associated with each return)
CREATE TABLE IF NOT EXISTS public.return_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL REFERENCES public.returns(id) ON DELETE CASCADE,
    order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
    quantity INT NOT NULL CHECK (quantity > 0),
    reason_category return_reason_category NOT NULL DEFAULT 'other',
    customer_reason_note TEXT,
    condition item_condition NOT NULL DEFAULT 'unopened',
    disposition disposition_action NOT NULL DEFAULT 'pending_inspection',
    refund_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. AUTOMATIC TIMESTAMPS TRIGGERS
DROP TRIGGER IF EXISTS trg_stores_updated_at ON public.stores;
CREATE TRIGGER trg_stores_updated_at
    BEFORE UPDATE ON public.stores
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_returns_updated_at ON public.returns;
CREATE TRIGGER trg_returns_updated_at
    BEFORE UPDATE ON public.returns
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 6. PERFORMANCE INDEXES
CREATE INDEX IF NOT EXISTS idx_products_store_id ON public.products(store_id);
CREATE INDEX IF NOT EXISTS idx_orders_store_id ON public.orders(store_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_email ON public.orders(customer_email);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS idx_returns_store_id ON public.returns(store_id);
CREATE INDEX IF NOT EXISTS idx_returns_order_id ON public.returns(order_id);
CREATE INDEX IF NOT EXISTS idx_returns_status ON public.returns(status);
CREATE INDEX IF NOT EXISTS idx_returns_risk_tier ON public.returns(risk_tier);
CREATE INDEX IF NOT EXISTS idx_return_items_return_id ON public.return_items(return_id);
CREATE INDEX IF NOT EXISTS idx_return_items_reason_category ON public.return_items(reason_category);

-- 7. ANALYTICS & INTELLIGENCE VIEWS (Clean PostgREST-ready API contracts)

-- View 1: ReturnIQ Executive Metrics
CREATE OR REPLACE VIEW public.vw_returniq_overview AS
SELECT
    s.id AS store_id,
    s.name AS store_name,
    COUNT(DISTINCT r.id) AS total_returns,
    COUNT(DISTINCT CASE WHEN r.status = 'requested' THEN r.id END) AS pending_review_count,
    COUNT(DISTINCT CASE WHEN r.status = 'approved' THEN r.id END) AS approved_count,
    COUNT(DISTINCT CASE WHEN r.status = 'rejected' THEN r.id END) AS rejected_count,
    COUNT(DISTINCT CASE WHEN r.risk_tier IN ('high', 'critical') THEN r.id END) AS high_risk_returns_count,
    COALESCE(SUM(r.estimated_refund_total), 0) AS total_return_value,
    COALESCE(ROUND(AVG(r.risk_score), 1), 0) AS average_risk_score
FROM public.stores s
LEFT JOIN public.returns r ON r.store_id = s.id
GROUP BY s.id, s.name;

-- View 2: Product Return Intelligence (Top returned products, rates, defect signals)
CREATE OR REPLACE VIEW public.vw_product_return_intelligence AS
SELECT
    p.id AS product_id,
    p.store_id,
    p.sku,
    p.title,
    p.category,
    p.retail_price,
    COALESCE(SUM(oi.quantity), 0) AS units_sold,
    COALESCE(SUM(ri.quantity), 0) AS units_returned,
    CASE 
        WHEN COALESCE(SUM(oi.quantity), 0) > 0 
        THEN ROUND((COALESCE(SUM(ri.quantity), 0)::NUMERIC / SUM(oi.quantity)::NUMERIC) * 100, 2)
        ELSE 0 
    END AS return_rate_percentage,
    MODE() WITHIN GROUP (ORDER BY ri.reason_category) AS primary_return_reason
FROM public.products p
LEFT JOIN public.order_items oi ON oi.product_id = p.id
LEFT JOIN public.return_items ri ON ri.order_item_id = oi.id
GROUP BY p.id, p.store_id, p.sku, p.title, p.category, p.retail_price;

-- View 3: Customer Return Behavior & Risk Profiling
CREATE OR REPLACE VIEW public.vw_customer_risk_profile AS
SELECT
    o.store_id,
    o.customer_email,
    o.customer_name,
    COUNT(DISTINCT o.id) AS total_orders_placed,
    COALESCE(SUM(o.total_amount), 0) AS total_spend,
    COUNT(DISTINCT r.id) AS total_returns_requested,
    COALESCE(SUM(r.estimated_refund_total), 0) AS total_refunded_or_requested,
    CASE 
        WHEN COUNT(DISTINCT o.id) > 0 
        THEN ROUND((COUNT(DISTINCT r.id)::NUMERIC / COUNT(DISTINCT o.id)::NUMERIC) * 100, 2)
        ELSE 0 
    END AS order_return_rate_percentage,
    MAX(r.created_at) AS latest_return_date
FROM public.orders o
LEFT JOIN public.returns r ON r.order_id = o.id
GROUP BY o.store_id, o.customer_email, o.customer_name;

-- 8. ROW LEVEL SECURITY (RLS) POLICIES
-- Enabling RLS on all base tables
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.return_items ENABLE ROW LEVEL SECURITY;

-- Hackathon Dev Policies (Permissive read/write access for development & future frontend wiring)
DROP POLICY IF EXISTS "Dev full access stores" ON public.stores;
CREATE POLICY "Dev full access stores" ON public.stores FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Dev full access products" ON public.products;
CREATE POLICY "Dev full access products" ON public.products FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Dev full access orders" ON public.orders;
CREATE POLICY "Dev full access orders" ON public.orders FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Dev full access order_items" ON public.order_items;
CREATE POLICY "Dev full access order_items" ON public.order_items FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Dev full access returns" ON public.returns;
CREATE POLICY "Dev full access returns" ON public.returns FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Dev full access return_items" ON public.return_items;
CREATE POLICY "Dev full access return_items" ON public.return_items FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
