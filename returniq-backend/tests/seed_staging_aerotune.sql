-- ==============================================================================
-- ReturnIQ Staging Environment Seed Script: AeroTune HB-09 Benchmark Scenario
-- File: tests/seed_staging_aerotune.sql
-- Environment: STAGING ONLY (DO NOT RUN IN PRODUCTION)
--
-- Purpose:
--   Seeds the canonical ReturnIQ reverse logistics benchmark dataset:
--     1. Supplier: SonicWave Electronics Ltd (SUP-SW-01)
--     2. Product: AeroTune Wireless Headphones (WH-AERO-01)
--     3. Supplier Batch: HB-09 (200 units, 20 days left in return window)
--     4. Returned Inventory: RET-HB09-2026 (40 units Grade B, 24 confirmed defects)
--
-- Safety Guarantees:
--   - Pre-flight conflict check: verifies that none of the target IDs or unique
--     business keys exist before modifying anything. If any conflict is found,
--     the entire execution halts immediately with RAISE EXCEPTION.
--   - No ON CONFLICT DO UPDATE: will never overwrite or mutate existing data.
--   - Full in-transaction assertions: verifies all 4 inserts, the quality-alert
--     trigger firing (12.00% critical defect alert), and fn_evaluate_recovery_options
--     BEFORE committing. If any assertion fails, the entire transaction rolls back.
--   - All-or-nothing atomicity: wrapped in BEGIN ... COMMIT.
-- ==============================================================================

BEGIN;

DO $$
DECLARE
    -- Deterministic staging UUIDs
    c_sup_id    CONSTANT UUID := 'a0000000-0000-0000-0000-000000000001'::uuid;
    c_prod_id   CONSTANT UUID := 'b0000000-0000-0000-0000-000000000001'::uuid;
    c_batch_id  CONSTANT UUID := 'c0000000-0000-0000-0000-000000000001'::uuid;
    c_return_id CONSTANT UUID := 'd0000000-0000-0000-0000-000000000001'::uuid;

    -- Dynamic capture variables
    v_sup_id    UUID;
    v_prod_id   UUID;
    v_batch_id  UUID;
    v_return_id UUID;

    -- In-transaction assertion variables
    v_alert_count INT;
    v_alert_rec   RECORD;
    v_eval_count  INT;
BEGIN
    RAISE NOTICE '=============================================================';
    RAISE NOTICE 'ReturnIQ Staging Seed: Starting Pre-flight Conflict Checks...';
    RAISE NOTICE '=============================================================';

    -- ------------------------------------------------------------------
    -- 1. PRE-FLIGHT CONFLICT CHECKS (ABORT WITHOUT WRITING IF ANY EXIST)
    -- ------------------------------------------------------------------

    -- Check Fixed UUIDs
    IF EXISTS (SELECT 1 FROM public.suppliers WHERE id = c_sup_id) THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Supplier ID % already exists in public.suppliers.', c_sup_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.products WHERE id = c_prod_id) THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Product ID % already exists in public.products.', c_prod_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.supplier_batches WHERE id = c_batch_id) THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Batch ID % already exists in public.supplier_batches.', c_batch_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.returned_inventory WHERE id = c_return_id) THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Return ID % already exists in public.returned_inventory.', c_return_id;
    END IF;

    -- Check Unique Business Keys
    IF EXISTS (SELECT 1 FROM public.suppliers WHERE code = 'SUP-SW-01') THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Supplier code "SUP-SW-01" already exists in public.suppliers.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.products WHERE sku = 'WH-AERO-01') THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Product SKU "WH-AERO-01" already exists in public.products.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.supplier_batches WHERE batch_code = 'HB-09') THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Batch code "HB-09" already exists in public.supplier_batches.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.returned_inventory WHERE return_tracking_id = 'RET-HB09-2026') THEN
        RAISE EXCEPTION 'CONFLICT ABORT: Return tracking ID "RET-HB09-2026" already exists in public.returned_inventory.';
    END IF;

    RAISE NOTICE 'Pre-flight checks passed. Zero conflicts detected.';

    -- ------------------------------------------------------------------
    -- 2. SEQUENTIAL INSERTS (FOREIGN KEYS BOUND TO RETURNED IDS)
    -- ------------------------------------------------------------------

    -- Step 1: Supplier
    INSERT INTO public.suppliers (
        id,
        name,
        code,
        contact_email,
        default_return_window_days,
        default_credit_rate_pct
    ) VALUES (
        c_sup_id,
        'SonicWave Electronics Ltd',
        'SUP-SW-01',
        'support@sonicwave.io',
        30,
        60.00
    )
    RETURNING id INTO v_sup_id;

    -- Step 2: Product (referencing v_sup_id)
    INSERT INTO public.products (
        id,
        supplier_id,
        sku,
        name,
        category,
        cost_price_inr,
        mrp_inr,
        current_inventory_units,
        total_units_sold,
        daily_demand_velocity,
        refurb_cost_inr,
        refurb_turnaround_days,
        resale_price_pct_of_mrp,
        liquidation_rate_pct_of_cost
    ) VALUES (
        c_prod_id,
        v_sup_id,
        'WH-AERO-01',
        'AeroTune Wireless Headphones',
        'Audio',
        1400.00,
        2500.00,
        120,
        850,
        15.00,
        250.00,
        5,
        75.00,
        35.00
    )
    RETURNING id INTO v_prod_id;

    -- Step 3: Supplier Batch (referencing v_sup_id and v_prod_id)
    INSERT INTO public.supplier_batches (
        id,
        supplier_id,
        product_id,
        batch_code,
        received_date,
        vendor_window_basis_date,
        vendor_return_deadline,
        units_received,
        custom_credit_rate_pct,
        defect_threshold_pct,
        min_sample_size_for_alert
    ) VALUES (
        c_batch_id,
        v_sup_id,
        v_prod_id,
        'HB-09',
        CURRENT_DATE - INTERVAL '10 days',
        CURRENT_DATE - INTERVAL '10 days',
        CURRENT_DATE + INTERVAL '20 days',
        200,
        60.00,
        5.00,
        10
    )
    RETURNING id INTO v_batch_id;

    -- Step 4: Returned Inventory (referencing v_batch_id and v_prod_id)
    -- Inserting 24 vendor-eligible defects out of 200 units = 12% defect rate.
    -- Trigger trg_check_batch_defects fires AFTER INSERT automatically.
    INSERT INTO public.returned_inventory (
        id,
        batch_id,
        product_id,
        return_tracking_id,
        returned_units,
        return_date,
        item_grade,
        return_reason,
        is_confirmed_defect,
        vendor_eligible_units,
        intake_status,
        notes
    ) VALUES (
        c_return_id,
        v_batch_id,
        v_prod_id,
        'RET-HB09-2026',
        40,
        CURRENT_DATE,
        'Grade B',
        'Repeated audio driver buzzing & connection drops',
        true,
        24,
        'inspected',
        'Batch HB-09 repeated fault pattern detected during bench inspection'
    )
    RETURNING id INTO v_return_id;

    -- ------------------------------------------------------------------
    -- 3. IN-TRANSACTION INTEGRITY & TRIGGER ASSERTIONS (PRE-COMMIT)
    -- ------------------------------------------------------------------

    -- Assertion 1: Quality-alert trigger created exactly 1 open critical alert
    SELECT COUNT(*) INTO v_alert_count
    FROM public.supplier_quality_alerts
    WHERE batch_id = v_batch_id AND status = 'open';

    SELECT severity, defect_rate_pct, confirmed_defective_units
    INTO v_alert_rec
    FROM public.supplier_quality_alerts
    WHERE batch_id = v_batch_id AND status = 'open'
    LIMIT 1;

    IF v_alert_count <> 1 THEN
        RAISE EXCEPTION 'TRIGGER VALIDATION FAILED: Expected 1 open alert, found %.', v_alert_count;
    END IF;

    IF v_alert_rec.severity <> 'critical'
       OR v_alert_rec.defect_rate_pct <> 12.00
       OR v_alert_rec.confirmed_defective_units <> 24 THEN
        RAISE EXCEPTION 'TRIGGER VALIDATION FAILED: Expected critical alert with 12.00%% defect rate and 24 units. Found severity: %, rate: %, units: %',
            v_alert_rec.severity, v_alert_rec.defect_rate_pct, v_alert_rec.confirmed_defective_units;
    END IF;

    -- Assertion 2: Decision function evaluates all 4 pathways without error
    SELECT COUNT(*) INTO v_eval_count
    FROM public.fn_evaluate_recovery_options(v_return_id);

    IF v_eval_count <> 4 THEN
        RAISE EXCEPTION 'EVALUATION ENGINE FAILED: Expected 4 evaluated pathways, found %.', v_eval_count;
    END IF;

    RAISE NOTICE '=============================================================';
    RAISE NOTICE 'All in-transaction assertions PASSED.';
    RAISE NOTICE 'Seed successful! Return ID: %', v_return_id;
    RAISE NOTICE 'Auto-triggered Quality Alert: Severity %, Defect Rate % %%', v_alert_rec.severity, v_alert_rec.defect_rate_pct;
    RAISE NOTICE '=============================================================';
END $$;

COMMIT;

-- ==============================================================================
-- POST-INSERT DIAGNOSTIC & VERIFICATION QUERIES (Read-Only)
-- These queries run after COMMIT to display results in your SQL tool.
-- ==============================================================================

-- Query 1: Verify Supplier Record
SELECT id, name, code, contact_email, default_return_window_days, default_credit_rate_pct
FROM public.suppliers
WHERE id = 'a0000000-0000-0000-0000-000000000001';

-- Query 2: Verify Product Record
SELECT id, sku, name, category, cost_price_inr, mrp_inr, daily_demand_velocity,
       refurb_cost_inr, resale_price_pct_of_mrp, liquidation_rate_pct_of_cost
FROM public.products
WHERE id = 'b0000000-0000-0000-0000-000000000001';

-- Query 3: Verify Supplier Batch Record & Days Left in Window
SELECT id, batch_code, units_received, vendor_window_basis_date, vendor_return_deadline,
       (vendor_return_deadline - CURRENT_DATE) AS days_remaining
FROM public.supplier_batches
WHERE id = 'c0000000-0000-0000-0000-000000000001';

-- Query 4: Verify Returned Inventory Intake Record
SELECT id, return_tracking_id, returned_units, item_grade, return_reason,
       is_confirmed_defect, vendor_eligible_units, intake_status
FROM public.returned_inventory
WHERE id = 'd0000000-0000-0000-0000-000000000001';

-- Query 5: Verify Automated Supplier Quality Alert (with relational JOINs to parent tables)
SELECT
    a.id AS alert_id,
    a.batch_id,
    a.batch_code,
    s.name AS supplier_name,
    p.sku AS product_sku,
    p.name AS product_name,
    a.units_received,
    a.confirmed_defective_units,
    a.defect_rate_pct,
    a.defect_threshold_pct,
    a.severity,
    a.status,
    a.alert_trigger_reason,
    a.created_at
FROM public.supplier_quality_alerts a
JOIN public.suppliers s ON s.id = a.supplier_id
JOIN public.products p ON p.id = a.product_id
WHERE a.batch_id = 'c0000000-0000-0000-0000-000000000001';

-- Query 6: Test Route Comparison Engine via fn_evaluate_recovery_options
SELECT route,
       is_eligible,
       ineligibility_reason,
       recovery_channel_type,
       eligible_units,
       unit_gross_recovery_inr,
       unit_cost_inr,
       unit_net_recovery_inr,
       potential_total_net_inr,
       estimated_days_to_realize,
       explanation
FROM public.fn_evaluate_recovery_options('d0000000-0000-0000-0000-000000000001');
