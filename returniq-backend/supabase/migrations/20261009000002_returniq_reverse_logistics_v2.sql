-- ==============================================================================
-- ReturnIQ Reverse Logistics & Quality Intelligence Schema (V2 Production-Ready)
-- Event: CYPHER 2026 Hackathon Prototype
-- Migration: 20261009000002_returniq_reverse_logistics_v2.sql
-- Currency: INR (Indian Rupees)
-- Architecture: Server-Side Mediated (RLS enabled, zero public access)
-- Concurrency: Row-locked allocation limits; dynamic reactive quality alerts
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. HELPER FUNCTIONS & TRIGGERS
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
    default_return_window_days INT NOT NULL DEFAULT 30 CHECK (default_return_window_days > 0),
    default_credit_rate_pct NUMERIC(5, 2) NOT NULL DEFAULT 100.00 CHECK (default_credit_rate_pct BETWEEN 0 AND 100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 2: Products (Catalog, Demand Velocity & Recovery Economic Baselines)
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
    
    -- Economic recovery baselines
    refurb_cost_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (refurb_cost_inr >= 0),
    refurb_turnaround_days INT NOT NULL DEFAULT 5 CHECK (refurb_turnaround_days >= 0),
    resale_price_pct_of_mrp NUMERIC(5, 2) NOT NULL DEFAULT 75.00 CHECK (resale_price_pct_of_mrp BETWEEN 0 AND 100),
    liquidation_rate_pct_of_cost NUMERIC(5, 2) NOT NULL DEFAULT 35.00 CHECK (liquidation_rate_pct_of_cost BETWEEN 0 AND 100),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 3: Supplier Batches (Inbound Lots & Explicit / Derived Vendor Return Windows)
CREATE TABLE IF NOT EXISTS public.supplier_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    batch_code TEXT NOT NULL,
    received_date DATE NOT NULL DEFAULT CURRENT_DATE,
    vendor_window_basis_date DATE NOT NULL DEFAULT CURRENT_DATE,
    vendor_return_deadline DATE NOT NULL,
    units_received INT NOT NULL CHECK (units_received > 0),
    custom_credit_rate_pct NUMERIC(5, 2) CHECK (custom_credit_rate_pct BETWEEN 0 AND 100),
    defect_threshold_pct NUMERIC(5, 2) NOT NULL DEFAULT 5.00 CHECK (defect_threshold_pct BETWEEN 0 AND 100),
    min_sample_size_for_alert INT NOT NULL DEFAULT 10 CHECK (min_sample_size_for_alert > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_batch UNIQUE (product_id, batch_code)
);

-- Trigger to auto-derive vendor_return_deadline if omitted
CREATE OR REPLACE FUNCTION trg_fn_set_vendor_return_deadline()
RETURNS TRIGGER AS $$
DECLARE
    v_window_days INT;
BEGIN
    IF NEW.vendor_return_deadline IS NULL THEN
        SELECT default_return_window_days INTO v_window_days
        FROM public.suppliers WHERE id = NEW.supplier_id;
        
        NEW.vendor_return_deadline := (NEW.vendor_window_basis_date + (COALESCE(v_window_days, 30) * INTERVAL '1 day'))::DATE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_batch_deadline ON public.supplier_batches;
CREATE TRIGGER trg_set_batch_deadline
    BEFORE INSERT OR UPDATE ON public.supplier_batches
    FOR EACH ROW EXECUTE FUNCTION trg_fn_set_vendor_return_deadline();

-- Table 4: Returned Inventory (Intake, Grade, Defect Distinction & Vendor Eligibility)
CREATE TABLE IF NOT EXISTS public.returned_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES public.supplier_batches(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    return_tracking_id TEXT NOT NULL UNIQUE,
    returned_units INT NOT NULL CHECK (returned_units > 0),
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    item_grade VARCHAR(10) NOT NULL CHECK (item_grade IN ('Grade A', 'Grade B', 'Grade C', 'Grade D')),
    return_reason TEXT NOT NULL,
    is_confirmed_defect BOOLEAN NOT NULL DEFAULT false,
    vendor_eligible_units INT NOT NULL DEFAULT 0 CHECK (vendor_eligible_units >= 0),
    intake_status VARCHAR(25) NOT NULL DEFAULT 'received' CHECK (intake_status IN ('received', 'inspected', 'allocated', 'completed')),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_vendor_units_le_returned CHECK (vendor_eligible_units <= returned_units)
);

-- Table 5: Recovery Plans (Batch / Return Header for Allocation)
CREATE TABLE IF NOT EXISTS public.recovery_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    returned_inventory_id UUID NOT NULL REFERENCES public.returned_inventory(id) ON DELETE CASCADE,
    plan_code TEXT NOT NULL UNIQUE,
    status VARCHAR(25) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'approved', 'rejected', 'executed')),
    manager_approved_by TEXT,
    manager_notes TEXT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 6: Recovery Allocations (Batch Splitting across Routes with Cash vs Credit Distinction)
CREATE TABLE IF NOT EXISTS public.recovery_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id UUID NOT NULL REFERENCES public.recovery_plans(id) ON DELETE CASCADE,
    route VARCHAR(30) NOT NULL CHECK (route IN ('restock', 'refurbish_and_resell', 'return_to_vendor', 'liquidation', 'scrap_recycle')),
    allocated_units INT NOT NULL CHECK (allocated_units > 0),
    recovery_channel_type VARCHAR(20) NOT NULL CHECK (recovery_channel_type IN ('cash', 'supplier_credit', 'none')),
    unit_gross_recovery_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (unit_gross_recovery_inr >= 0),
    unit_cost_inr NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (unit_cost_inr >= 0),
    total_gross_recovery_inr NUMERIC(12, 2) GENERATED ALWAYS AS (allocated_units * unit_gross_recovery_inr) STORED,
    total_cost_inr NUMERIC(12, 2) GENERATED ALWAYS AS (allocated_units * unit_cost_inr) STORED,
    total_net_recovery_inr NUMERIC(12, 2) GENERATED ALWAYS AS ((allocated_units * unit_gross_recovery_inr) - (allocated_units * unit_cost_inr)) STORED,
    estimated_days_to_realize INT NOT NULL DEFAULT 0 CHECK (estimated_days_to_realize >= 0),
    is_eligible BOOLEAN NOT NULL DEFAULT true,
    ineligibility_reason TEXT,
    allocation_rationale TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 7: Supplier Quality Alerts (Sample-Size & Defect-Aware)
CREATE TABLE IF NOT EXISTS public.supplier_quality_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES public.supplier_batches(id) ON DELETE CASCADE,
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_code TEXT NOT NULL,
    units_received INT NOT NULL,
    confirmed_defective_units INT NOT NULL,
    defect_rate_pct NUMERIC(5, 2) NOT NULL,
    defect_threshold_pct NUMERIC(5, 2) NOT NULL,
    severity VARCHAR(15) NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'disputed', 'resolved')),
    alert_trigger_reason TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

-- 4. BATCH SPLITTING INTEGRITY TRIGGER (Concurrency-safe & Cross-Plan Enforcement)
CREATE OR REPLACE FUNCTION trg_fn_validate_recovery_allocation_limits()
RETURNS TRIGGER AS $$
DECLARE
    v_plan_status VARCHAR(25);
    v_returned_inventory_id UUID;
    v_total_returned_units INT;
    v_vendor_eligible_units INT;
    v_total_allocated INT;
    v_rtv_allocated INT;
BEGIN
    -- 1. Identify parent return record, plan status, and lock return record exclusively
    SELECT p.status, p.returned_inventory_id, ri.returned_units, ri.vendor_eligible_units
    INTO v_plan_status, v_returned_inventory_id, v_total_returned_units, v_vendor_eligible_units
    FROM public.recovery_plans p
    JOIN public.returned_inventory ri ON ri.id = p.returned_inventory_id
    WHERE p.id = NEW.plan_id
    FOR UPDATE OF ri;

    -- 2. If the plan itself is rejected, its allocations do not consume inventory quotas.
    -- Quota validation is deferred until/if the plan is reactivated.
    IF v_plan_status = 'rejected' THEN
        RETURN NEW;
    END IF;

    -- 3. Compute total allocated units across ALL active/approved plans for this return record
    SELECT COALESCE(SUM(ra.allocated_units), 0)
    INTO v_total_allocated
    FROM public.recovery_allocations ra
    JOIN public.recovery_plans rp ON rp.id = ra.plan_id
    WHERE rp.returned_inventory_id = v_returned_inventory_id
      AND rp.status <> 'rejected'
      AND ra.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

    v_total_allocated := v_total_allocated + NEW.allocated_units;

    IF v_total_allocated > v_total_returned_units THEN
        RAISE EXCEPTION 'Allocation violation: Total allocated units across plans (%) exceeds available returned units (%).',
            v_total_allocated, v_total_returned_units;
    END IF;

    -- 3. If route is return_to_vendor, ensure allocated units across all plans do not exceed vendor_eligible_units
    IF NEW.route = 'return_to_vendor' THEN
        SELECT COALESCE(SUM(ra.allocated_units), 0)
        INTO v_rtv_allocated
        FROM public.recovery_allocations ra
        JOIN public.recovery_plans rp ON rp.id = ra.plan_id
        WHERE rp.returned_inventory_id = v_returned_inventory_id
          AND rp.status <> 'rejected'
          AND ra.route = 'return_to_vendor'
          AND ra.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

        v_rtv_allocated := v_rtv_allocated + NEW.allocated_units;

        IF v_rtv_allocated > v_vendor_eligible_units THEN
            RAISE EXCEPTION 'Vendor claim violation: Total allocated RTV units across plans (%) exceeds vendor-eligible units (%).',
                v_rtv_allocated, v_vendor_eligible_units;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_recovery_allocation ON public.recovery_allocations;
CREATE TRIGGER trg_validate_recovery_allocation
    BEFORE INSERT OR UPDATE ON public.recovery_allocations
    FOR EACH ROW EXECUTE FUNCTION trg_fn_validate_recovery_allocation_limits();

-- 4B. PLAN REACTIVATION INTEGRITY TRIGGER (Prevents un-rejecting plans that would exceed limits)
CREATE OR REPLACE FUNCTION trg_fn_validate_recovery_plan_reactivation()
RETURNS TRIGGER AS $$
DECLARE
    v_total_returned_units INT;
    v_vendor_eligible_units INT;
    v_total_allocated INT;
    v_rtv_allocated INT;
BEGIN
    -- Prevent reassigning plan to a different return record
    IF OLD.returned_inventory_id <> NEW.returned_inventory_id THEN
        RAISE EXCEPTION 'Immutable reference: Cannot reassign recovery plan % to a different return record.', NEW.plan_code;
    END IF;

    -- Only validate when transitioning from 'rejected' to an active status (e.g. 'approved', 'draft', 'pending_approval')
    IF OLD.status = 'rejected' AND NEW.status <> 'rejected' THEN
        -- Acquire exclusive lock on parent return record to synchronize concurrent transactions
        SELECT ri.returned_units, ri.vendor_eligible_units
        INTO v_total_returned_units, v_vendor_eligible_units
        FROM public.returned_inventory ri
        WHERE ri.id = NEW.returned_inventory_id
        FOR UPDATE OF ri;

        -- Sum all allocations across other active plans plus this reactivating plan
        SELECT COALESCE(SUM(ra.allocated_units), 0)
        INTO v_total_allocated
        FROM public.recovery_allocations ra
        JOIN public.recovery_plans rp ON rp.id = ra.plan_id
        WHERE rp.returned_inventory_id = NEW.returned_inventory_id
          AND (rp.status <> 'rejected' OR rp.id = NEW.id);

        IF v_total_allocated > v_total_returned_units THEN
            RAISE EXCEPTION 'Plan reactivation violation: Activating plan % would cause total allocated units (%) to exceed available returned units (%).',
                NEW.plan_code, v_total_allocated, v_total_returned_units;
        END IF;

        -- Check RTV allocations against vendor-eligible units
        SELECT COALESCE(SUM(ra.allocated_units), 0)
        INTO v_rtv_allocated
        FROM public.recovery_allocations ra
        JOIN public.recovery_plans rp ON rp.id = ra.plan_id
        WHERE rp.returned_inventory_id = NEW.returned_inventory_id
          AND (rp.status <> 'rejected' OR rp.id = NEW.id)
          AND ra.route = 'return_to_vendor';

        IF v_rtv_allocated > v_vendor_eligible_units THEN
            RAISE EXCEPTION 'Plan reactivation violation: Activating plan % would cause total RTV units (%) to exceed vendor-eligible units (%).',
                NEW.plan_code, v_rtv_allocated, v_vendor_eligible_units;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_recovery_plan_reactivation ON public.recovery_plans;
CREATE TRIGGER trg_validate_recovery_plan_reactivation
    BEFORE UPDATE ON public.recovery_plans
    FOR EACH ROW EXECUTE FUNCTION trg_fn_validate_recovery_plan_reactivation();

-- 5. DYNAMIC QUALITY ALERT ENGINE (Handles INSERT, UPDATE, RECLASSIFY, and DELETE)
CREATE OR REPLACE FUNCTION public.fn_recalculate_batch_quality_alert(p_batch_id UUID)
RETURNS VOID AS $$
DECLARE
    v_batch RECORD;
    v_confirmed_defects INT;
    v_defect_rate NUMERIC(5, 2);
    v_severity VARCHAR(15);
    v_alert_id UUID;
BEGIN
    SELECT b.*, s.id as sup_id
    INTO v_batch
    FROM public.supplier_batches b
    JOIN public.suppliers s ON s.id = b.supplier_id
    WHERE b.id = p_batch_id;
    
    IF NOT FOUND THEN RETURN; END IF;

    -- Count confirmed defects only (ignoring buyer remorse or customer preference)
    SELECT COALESCE(SUM(vendor_eligible_units), 0)
    INTO v_confirmed_defects
    FROM public.returned_inventory
    WHERE batch_id = p_batch_id AND is_confirmed_defect = true;

    -- Check if an open alert already exists
    SELECT id INTO v_alert_id
    FROM public.supplier_quality_alerts
    WHERE batch_id = p_batch_id AND status = 'open';

    -- Evaluate against minimum sample size
    IF v_batch.units_received >= v_batch.min_sample_size_for_alert THEN
        v_defect_rate := ROUND((v_confirmed_defects::NUMERIC / v_batch.units_received::NUMERIC) * 100, 2);

        IF v_defect_rate >= v_batch.defect_threshold_pct THEN
            IF v_defect_rate >= (v_batch.defect_threshold_pct * 2) THEN
                v_severity := 'critical';
            ELSE
                v_severity := 'warning';
            END IF;

            IF v_alert_id IS NOT NULL THEN
                -- Update existing open alert with newly recalculated numbers
                UPDATE public.supplier_quality_alerts
                SET confirmed_defective_units = v_confirmed_defects,
                    defect_rate_pct = v_defect_rate,
                    severity = v_severity,
                    alert_trigger_reason = FORMAT('Batch %s defect rate of %s%% exceeds threshold of %s%% with %s confirmed defective units.',
                                                  v_batch.batch_code, v_defect_rate, v_batch.defect_threshold_pct, v_confirmed_defects)
                WHERE id = v_alert_id;
            ELSE
                -- Insert fresh alert
                INSERT INTO public.supplier_quality_alerts (
                    batch_id, supplier_id, product_id, batch_code,
                    units_received, confirmed_defective_units,
                    defect_rate_pct, defect_threshold_pct, severity,
                    alert_trigger_reason
                ) VALUES (
                    v_batch.id, v_batch.sup_id, v_batch.product_id, v_batch.batch_code,
                    v_batch.units_received, v_confirmed_defects,
                    v_defect_rate, v_batch.defect_threshold_pct, v_severity,
                    FORMAT('Batch %s defect rate of %s%% exceeds threshold of %s%% with %s confirmed defective units.',
                           v_batch.batch_code, v_defect_rate, v_batch.defect_threshold_pct, v_confirmed_defects)
                );
            END IF;
        ELSE
            -- Defect rate has dropped below threshold (due to reclassification, edits, or deletion)
            IF v_alert_id IS NOT NULL THEN
                UPDATE public.supplier_quality_alerts
                SET status = 'resolved',
                    resolved_at = NOW(),
                    confirmed_defective_units = v_confirmed_defects,
                    defect_rate_pct = v_defect_rate,
                    alert_trigger_reason = FORMAT('Resolved: Batch %s defect rate dropped to %s%% (below %s%% threshold).',
                                                  v_batch.batch_code, v_defect_rate, v_batch.defect_threshold_pct)
                WHERE id = v_alert_id;
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_fn_check_supplier_batch_defects()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM public.fn_recalculate_batch_quality_alert(OLD.batch_id);
    ELSIF TG_OP = 'UPDATE' THEN
        PERFORM public.fn_recalculate_batch_quality_alert(NEW.batch_id);
        IF OLD.batch_id <> NEW.batch_id THEN
            PERFORM public.fn_recalculate_batch_quality_alert(OLD.batch_id);
        END IF;
    ELSE
        PERFORM public.fn_recalculate_batch_quality_alert(NEW.batch_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_batch_defects ON public.returned_inventory;
CREATE TRIGGER trg_check_batch_defects
    AFTER INSERT OR UPDATE OR DELETE ON public.returned_inventory
    FOR EACH ROW EXECUTE FUNCTION trg_fn_check_supplier_batch_defects();

-- 6. ROUTE COMPARISON DECISION FUNCTION (Compares all 4 pathways with demand & condition rules)
CREATE OR REPLACE FUNCTION fn_evaluate_recovery_options(p_return_id UUID)
RETURNS TABLE (
    route VARCHAR(30),
    is_eligible BOOLEAN,
    ineligibility_reason TEXT,
    recovery_channel_type VARCHAR(20),
    eligible_units INT,
    unit_gross_recovery_inr NUMERIC(12, 2),
    unit_cost_inr NUMERIC(12, 2),
    unit_net_recovery_inr NUMERIC(12, 2),
    potential_total_net_inr NUMERIC(12, 2),
    estimated_days_to_realize INT,
    explanation TEXT
) AS $$
DECLARE
    v_ret RECORD;
    v_prod RECORD;
    v_batch RECORD;
    v_sup RECORD;
    v_is_rtv_active BOOLEAN;
    v_days_left_rtv INT;
    v_credit_pct NUMERIC(5, 2);
    v_resale_price NUMERIC(12, 2);
    v_liquid_price NUMERIC(12, 2);
    v_days_of_supply NUMERIC(10, 1);
BEGIN
    SELECT * INTO v_ret FROM public.returned_inventory WHERE id = p_return_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT * INTO v_prod FROM public.products WHERE id = v_ret.product_id;
    SELECT * INTO v_batch FROM public.supplier_batches WHERE id = v_ret.batch_id;
    SELECT * INTO v_sup FROM public.suppliers WHERE id = v_prod.supplier_id;

    v_is_rtv_active := (CURRENT_DATE <= v_batch.vendor_return_deadline);
    v_days_left_rtv := GREATEST(0, (v_batch.vendor_return_deadline - CURRENT_DATE));
    v_credit_pct := COALESCE(v_batch.custom_credit_rate_pct, v_sup.default_credit_rate_pct);

    v_resale_price := ROUND(v_prod.mrp_inr * (v_prod.resale_price_pct_of_mrp / 100.0), 2);
    v_liquid_price := ROUND(v_prod.cost_price_inr * (v_prod.liquidation_rate_pct_of_cost / 100.0), 2);
    v_days_of_supply := CASE WHEN v_prod.daily_demand_velocity > 0 THEN v_prod.current_inventory_units / v_prod.daily_demand_velocity ELSE 999 END;

    -- 1. Restock Route
    route := 'restock';
    recovery_channel_type := 'cash';
    unit_gross_recovery_inr := v_prod.mrp_inr;
    unit_cost_inr := 0.00;
    unit_net_recovery_inr := unit_gross_recovery_inr;
    estimated_days_to_realize := 1;
    IF v_ret.item_grade <> 'Grade A' THEN
        is_eligible := false;
        eligible_units := 0;
        ineligibility_reason := 'Direct restock is only permissible for Grade A (like-new) condition.';
        potential_total_net_inr := 0.00;
        explanation := 'Item condition does not meet Grade A standard.';
    ELSE
        is_eligible := true;
        eligible_units := v_ret.returned_units;
        ineligibility_reason := NULL;
        potential_total_net_inr := eligible_units * unit_net_recovery_inr;
        explanation := 'Grade A item eligible for immediate inventory replenishment.';
    END IF;
    RETURN NEXT;

    -- 2. Return to Vendor (RTV)
    route := 'return_to_vendor';
    recovery_channel_type := 'supplier_credit';
    unit_gross_recovery_inr := ROUND(v_prod.cost_price_inr * (v_credit_pct / 100.0), 2);
    unit_cost_inr := 0.00;
    unit_net_recovery_inr := unit_gross_recovery_inr;
    estimated_days_to_realize := 14;
    IF NOT v_is_rtv_active THEN
        is_eligible := false;
        eligible_units := 0;
        ineligibility_reason := FORMAT('Vendor return deadline expired on %s.', v_batch.vendor_return_deadline);
        potential_total_net_inr := 0.00;
        explanation := 'Batch is past the contractual vendor return window.';
    ELSIF v_ret.vendor_eligible_units <= 0 THEN
        is_eligible := false;
        eligible_units := 0;
        ineligibility_reason := 'Zero units classified as vendor-fault eligible.';
        potential_total_net_inr := 0.00;
        explanation := 'No vendor-claimable defects identified.';
    ELSE
        is_eligible := true;
        eligible_units := v_ret.vendor_eligible_units;
        ineligibility_reason := NULL;
        potential_total_net_inr := eligible_units * unit_net_recovery_inr;
        explanation := FORMAT('Eligible for %s%% vendor credit (%s days remaining in window).', v_credit_pct, v_days_left_rtv);
    END IF;
    RETURN NEXT;

    -- 3. Refurbish and Resell
    route := 'refurbish_and_resell';
    recovery_channel_type := 'cash';
    unit_gross_recovery_inr := v_resale_price;
    unit_cost_inr := v_prod.refurb_cost_inr;
    unit_net_recovery_inr := unit_gross_recovery_inr - unit_cost_inr;
    estimated_days_to_realize := v_prod.refurb_turnaround_days;
    IF v_ret.item_grade IN ('Grade C', 'Grade D') THEN
        is_eligible := false;
        eligible_units := 0;
        ineligibility_reason := 'Grade C/D damage exceeds economic refurbishment viability.';
        potential_total_net_inr := 0.00;
        explanation := 'Severe damage makes refurbishment cost-ineffective.';
    ELSIF v_prod.daily_demand_velocity = 0 OR (v_prod.daily_demand_velocity <= 0.05 AND v_days_of_supply > 90) THEN
        is_eligible := false;
        eligible_units := 0;
        ineligibility_reason := FORMAT('Insufficient demand velocity (%s units/day) with %s days existing supply.', v_prod.daily_demand_velocity, v_days_of_supply);
        potential_total_net_inr := 0.00;
        explanation := 'Refurbishment not advised due to slow-moving inventory risk.';
    ELSE
        is_eligible := true;
        eligible_units := v_ret.returned_units;
        ineligibility_reason := NULL;
        potential_total_net_inr := eligible_units * unit_net_recovery_inr;
        explanation := FORMAT('Resale at %s%% of MRP (₹%s) yielding ₹%s net margin after ₹%s refurb cost.',
                              v_prod.resale_price_pct_of_mrp, unit_gross_recovery_inr, unit_net_recovery_inr, unit_cost_inr);
    END IF;
    RETURN NEXT;

    -- 4. Liquidation
    route := 'liquidation';
    recovery_channel_type := 'cash';
    unit_gross_recovery_inr := v_liquid_price;
    unit_cost_inr := 0.00;
    unit_net_recovery_inr := unit_gross_recovery_inr;
    estimated_days_to_realize := 3;
    is_eligible := true;
    eligible_units := v_ret.returned_units;
    ineligibility_reason := NULL;
    potential_total_net_inr := eligible_units * unit_net_recovery_inr;
    explanation := FORMAT('Instant B2B liquidation recovery at %s%% of cost price (₹%s/unit).',
                          v_prod.liquidation_rate_pct_of_cost, unit_gross_recovery_inr);
    RETURN NEXT;

END;
$$ LANGUAGE plpgsql;

-- 7. ESSENTIAL INDEXES
CREATE INDEX IF NOT EXISTS idx_products_supplier ON public.products(supplier_id);
CREATE INDEX IF NOT EXISTS idx_batches_product ON public.supplier_batches(product_id);
CREATE INDEX IF NOT EXISTS idx_batches_deadline ON public.supplier_batches(vendor_return_deadline);
CREATE INDEX IF NOT EXISTS idx_returns_batch ON public.returned_inventory(batch_id);
CREATE INDEX IF NOT EXISTS idx_returns_defect ON public.returned_inventory(is_confirmed_defect);
CREATE INDEX IF NOT EXISTS idx_plans_return ON public.recovery_plans(returned_inventory_id);
CREATE INDEX IF NOT EXISTS idx_allocations_plan ON public.recovery_allocations(plan_id);
CREATE INDEX IF NOT EXISTS idx_allocations_route ON public.recovery_allocations(route);
CREATE INDEX IF NOT EXISTS idx_alerts_batch ON public.supplier_quality_alerts(batch_id);

-- 8. ANALYTICS VIEWS (Strict subquery pre-aggregation to eliminate double-counting)

-- View 1: Vendor Compliance, Quality & Explicit Return Window Tracking
CREATE OR REPLACE VIEW public.vw_vendor_compliance_and_rtv AS
SELECT
    b.id AS batch_id,
    b.batch_code,
    s.id AS supplier_id,
    s.name AS supplier_name,
    p.id AS product_id,
    p.sku,
    p.name AS product_name,
    b.units_received,
    COALESCE(r.total_returned, 0) AS units_returned,
    COALESCE(r.confirmed_defects, 0) AS confirmed_defect_units,
    ROUND(
        (COALESCE(r.confirmed_defects, 0)::NUMERIC / b.units_received::NUMERIC) * 100, 2
    ) AS confirmed_defect_rate_pct,
    b.defect_threshold_pct,
    b.vendor_window_basis_date,
    b.vendor_return_deadline,
    CURRENT_DATE <= b.vendor_return_deadline AS is_vendor_window_active,
    GREATEST(0, (b.vendor_return_deadline - CURRENT_DATE)) AS days_remaining_in_window,
    COALESCE(r.vendor_eligible_units, 0) AS total_vendor_eligible_units,
    ROUND(
        (COALESCE(r.vendor_eligible_units, 0) * p.cost_price_inr * (COALESCE(b.custom_credit_rate_pct, s.default_credit_rate_pct) / 100.0)),
        2
    ) AS potential_vendor_credit_inr
FROM public.supplier_batches b
JOIN public.suppliers s ON s.id = b.supplier_id
JOIN public.products p ON p.id = b.product_id
LEFT JOIN (
    SELECT
        batch_id,
        SUM(returned_units) AS total_returned,
        SUM(CASE WHEN is_confirmed_defect THEN vendor_eligible_units ELSE 0 END) AS confirmed_defects,
        SUM(vendor_eligible_units) AS vendor_eligible_units
    FROM public.returned_inventory
    GROUP BY batch_id
) r ON r.batch_id = b.id;

-- View 2: Executive Recovery Pipeline (Distinguishes Cash vs. Supplier Credit in INR; excludes rejected plans)
CREATE OR REPLACE VIEW public.vw_recovery_pipeline_summary AS
SELECT
    COUNT(DISTINCT p.id) AS total_plans,
    COUNT(DISTINCT CASE WHEN p.status = 'approved' THEN p.id END) AS approved_plans_count,
    COUNT(DISTINCT CASE WHEN p.status = 'pending_approval' THEN p.id END) AS pending_approval_count,
    
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.recovery_channel_type = 'cash' THEN a.total_gross_recovery_inr ELSE 0 END), 0) AS gross_cash_recovery_inr,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.recovery_channel_type = 'cash' THEN a.total_cost_inr ELSE 0 END), 0) AS cash_recovery_costs_inr,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.recovery_channel_type = 'cash' THEN a.total_net_recovery_inr ELSE 0 END), 0) AS net_cash_recovery_inr,
    
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.recovery_channel_type = 'supplier_credit' THEN a.total_net_recovery_inr ELSE 0 END), 0) AS net_supplier_credit_inr,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' THEN a.total_net_recovery_inr ELSE 0 END), 0) AS total_combined_recovery_inr,
    
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.route = 'return_to_vendor' THEN a.allocated_units ELSE 0 END), 0) AS rtv_units,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.route = 'refurbish_and_resell' THEN a.allocated_units ELSE 0 END), 0) AS refurbish_units,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.route = 'liquidation' THEN a.allocated_units ELSE 0 END), 0) AS liquidation_units,
    COALESCE(SUM(CASE WHEN p.status <> 'rejected' AND a.route = 'restock' THEN a.allocated_units ELSE 0 END), 0) AS restock_units
FROM public.recovery_plans p
LEFT JOIN public.recovery_allocations a ON a.plan_id = p.id;

-- View 3: Product Inventory, Demand Velocity & Defect Overview
CREATE OR REPLACE VIEW public.vw_product_demand_and_inventory AS
SELECT
    p.id AS product_id,
    p.sku,
    p.name AS product_name,
    p.category,
    p.cost_price_inr,
    p.mrp_inr,
    p.current_inventory_units,
    p.total_units_sold,
    p.daily_demand_velocity,
    CASE 
        WHEN p.daily_demand_velocity > 0 THEN ROUND((p.current_inventory_units::NUMERIC / p.daily_demand_velocity), 1)
        ELSE NULL 
    END AS days_of_supply,
    COALESCE(ri.total_returned, 0) AS total_returned_units,
    COALESCE(ri.confirmed_defects, 0) AS confirmed_defect_units,
    CASE 
        WHEN p.total_units_sold > 0 THEN ROUND((COALESCE(ri.total_returned, 0)::NUMERIC / p.total_units_sold::NUMERIC) * 100, 2)
        ELSE 0.00 
    END AS return_rate_pct,
    CASE 
        WHEN p.total_units_sold > 0 THEN ROUND((COALESCE(ri.confirmed_defects, 0)::NUMERIC / p.total_units_sold::NUMERIC) * 100, 2)
        ELSE 0.00 
    END AS defect_rate_pct
FROM public.products p
LEFT JOIN (
    SELECT 
        product_id,
        SUM(returned_units) AS total_returned,
        SUM(CASE WHEN is_confirmed_defect THEN vendor_eligible_units ELSE 0 END) AS confirmed_defects
    FROM public.returned_inventory
    GROUP BY product_id
) ri ON ri.product_id = p.id;

-- 9. ROW LEVEL SECURITY (RLS)
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.returned_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recovery_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recovery_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_quality_alerts ENABLE ROW LEVEL SECURITY;
