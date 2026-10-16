-- ==============================================================================
-- ReturnIQ Migration: Gadgetbay Challenge 10 Schema
-- Timestamp: 2026-10-10
-- Purpose: Create isolated, idempotent dataset tables for the 7 Gadgetbay Challenge 10 CSVs
-- Safe: Does not modify or drop existing tables (products, returned_inventory, etc.)
-- ==============================================================================

-- 1. Master Products
CREATE TABLE IF NOT EXISTS public.gb_products (
    sku VARCHAR(30) PRIMARY KEY,
    product VARCHAR(150) NOT NULL,
    category VARCHAR(50) NOT NULL,
    cost_price NUMERIC(12, 2) NOT NULL,
    selling_price NUMERIC(12, 2) NOT NULL,
    supplier VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gb_products_category ON public.gb_products(category);
CREATE INDEX IF NOT EXISTS idx_gb_products_supplier ON public.gb_products(supplier);

-- 2. Current Inventory & Demand
CREATE TABLE IF NOT EXISTS public.gb_inventory (
    sku VARCHAR(30) PRIMARY KEY REFERENCES public.gb_products(sku) ON DELETE CASCADE,
    new_stock INT NOT NULL DEFAULT 0,
    avg_daily_demand NUMERIC(8, 2) NOT NULL DEFAULT 0.0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Supplier Terms & RTV Rules
CREATE TABLE IF NOT EXISTS public.gb_vendor_terms (
    sku VARCHAR(30) PRIMARY KEY REFERENCES public.gb_products(sku) ON DELETE CASCADE,
    supplier VARCHAR(100) NOT NULL,
    rtv_allowed BOOLEAN NOT NULL DEFAULT FALSE,
    credit_pct NUMERIC(5, 2) NOT NULL DEFAULT 0.0,
    window_days INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Category Refurbishment Matrix
CREATE TABLE IF NOT EXISTS public.gb_refurbishment (
    category VARCHAR(50) PRIMARY KEY,
    refurb_cost NUMERIC(12, 2) NOT NULL,
    days_required INT NOT NULL,
    resale_pct_of_new NUMERIC(5, 2) NOT NULL
);

-- 5. Liquidation Recovery Rates Matrix
CREATE TABLE IF NOT EXISTS public.gb_liquidation (
    category VARCHAR(50) NOT NULL,
    condition_grade VARCHAR(5) NOT NULL,
    recovery_pct_of_cost NUMERIC(5, 2) NOT NULL,
    PRIMARY KEY (category, condition_grade)
);

-- 6. Returns Ledger
CREATE TABLE IF NOT EXISTS public.gb_returns (
    return_id VARCHAR(30) PRIMARY KEY,
    date_received DATE NOT NULL,
    sku VARCHAR(30) NOT NULL REFERENCES public.gb_products(sku) ON DELETE RESTRICT,
    supplier_batch VARCHAR(50),
    reason_code VARCHAR(100),
    condition_grade VARCHAR(5) NOT NULL,
    status VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gb_returns_sku ON public.gb_returns(sku);
CREATE INDEX IF NOT EXISTS idx_gb_returns_date ON public.gb_returns(date_received);
CREATE INDEX IF NOT EXISTS idx_gb_returns_status ON public.gb_returns(status);
CREATE INDEX IF NOT EXISTS idx_gb_returns_grade ON public.gb_returns(condition_grade);

-- 7. Sales History
CREATE TABLE IF NOT EXISTS public.gb_sales (
    date DATE NOT NULL,
    sku VARCHAR(30) NOT NULL REFERENCES public.gb_products(sku) ON DELETE CASCADE,
    qty_sold INT NOT NULL DEFAULT 1,
    selling_price NUMERIC(12, 2) NOT NULL,
    PRIMARY KEY (date, sku)
);

CREATE INDEX IF NOT EXISTS idx_gb_sales_sku ON public.gb_sales(sku);
CREATE INDEX IF NOT EXISTS idx_gb_sales_date ON public.gb_sales(date);

-- Security: Enable RLS on all 7 tables
ALTER TABLE public.gb_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_vendor_terms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_refurbishment ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_liquidation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gb_sales ENABLE ROW LEVEL SECURITY;
