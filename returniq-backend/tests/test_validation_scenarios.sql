-- ==============================================================================
-- ReturnIQ CYPHER 2026 Test Scenario & Validation Script (Complete Suite)
-- File: tests/test_validation_scenarios.sql
-- Description:
--   Executes automated end-to-end assertions covering:
--   1. Wireless Headphones Hackathon Demo Scenario (40 units, Batch HB-09)
--   2. Explicit Vendor return window calculation & remaining days
--   3. Concurrency-safe batch-splitting integrity (trigger prevents over-allocation)
--   4. Route comparison (Restock, Refurbish, RTV, Liquidation)
--   5. Supplier quality alert generation based on confirmed defects
--   6. Dynamic quality alert reclassification & auto-resolution test
--   7. Zero double-counting validation across executive views
-- ==============================================================================

-- Start transaction block for safe, automatic rollback
BEGIN;

DO $$
DECLARE
    v_sup_id UUID;
    v_prod_id UUID;
    v_batch_id UUID;
    v_return_id UUID;
    v_plan_id UUID;
    v_alert_count INT;
    v_alert_rec RECORD;
    v_calc_rtv_credit NUMERIC(12, 2);
    v_calc_refurb_net NUMERIC(12, 2);
    v_pipeline_net NUMERIC(12, 2);
    v_pipeline_credit NUMERIC(12, 2);
    v_pipeline_cash NUMERIC(12, 2);
    v_base_pipeline_net NUMERIC(12, 2) := 0.00;
    v_base_pipeline_credit NUMERIC(12, 2) := 0.00;
    v_base_pipeline_cash NUMERIC(12, 2) := 0.00;
    v_test_suffix TEXT := '_' || SUBSTRING(gen_random_uuid()::text FROM 1 FOR 8);
    v_error_caught BOOLEAN := false;
BEGIN
    RAISE NOTICE '=====================================================';
    RAISE NOTICE 'Starting ReturnIQ CYPHER 2026 Validation Suite...';
    RAISE NOTICE '=====================================================';

    -- ------------------------------------------------------------------
    -- BASELINE: Capture pipeline totals prior to test seed insertion
    -- Ensures Test 6 assertions remain valid when unrelated plans exist.
    -- ------------------------------------------------------------------
    SELECT
        COALESCE(net_cash_recovery_inr, 0.00),
        COALESCE(net_supplier_credit_inr, 0.00),
        COALESCE(total_combined_recovery_inr, 0.00)
    INTO
        v_base_pipeline_cash,
        v_base_pipeline_credit,
        v_base_pipeline_net
    FROM public.vw_recovery_pipeline_summary;

    -- ------------------------------------------------------------------
    -- STEP 1: SEED HACKATHON DEMO DATA
    -- Unique dynamic suffixes prevent collisions with existing records.
    -- ------------------------------------------------------------------
    
    -- 1. Supplier: SonicWave Electronics Ltd
    INSERT INTO public.suppliers (name, code, contact_email, default_return_window_days, default_credit_rate_pct)
    VALUES ('SonicWave Electronics Ltd', 'SUP-SW-01' || v_test_suffix, 'support@sonicwave.io', 30, 60.00)
    RETURNING id INTO v_sup_id;

    -- 2. Product: AeroTune Wireless Headphones
    -- MRP: ₹2,500, Cost: ₹1,400, Refurb Cost: ₹250, Refurb Days: 5, Resale: 75% MRP, Liquidation: 35% Cost
    INSERT INTO public.products (
        supplier_id, sku, name, category,
        cost_price_inr, mrp_inr, current_inventory_units, total_units_sold, daily_demand_velocity,
        refurb_cost_inr, refurb_turnaround_days, resale_price_pct_of_mrp, liquidation_rate_pct_of_cost
    ) VALUES (
        v_sup_id, 'WH-AERO-01' || v_test_suffix, 'AeroTune Wireless Headphones', 'Audio',
        1400.00, 2500.00, 120, 850, 15.00,
        250.00, 5, 75.00, 35.00
    ) RETURNING id INTO v_prod_id;

    -- 3. Supplier Batch: HB-09
    -- 200 units received 10 days ago. Explicit vendor deadline set 20 days ahead.
    INSERT INTO public.supplier_batches (
        supplier_id, product_id, batch_code,
        received_date, vendor_window_basis_date, vendor_return_deadline,
        units_received, custom_credit_rate_pct, defect_threshold_pct, min_sample_size_for_alert
    ) VALUES (
        v_sup_id, v_prod_id, 'HB-09' || v_test_suffix,
        CURRENT_DATE - INTERVAL '10 days',
        CURRENT_DATE - INTERVAL '10 days',
        CURRENT_DATE + INTERVAL '20 days',
        200, 60.00, 5.00, 10
    ) RETURNING id INTO v_batch_id;

    -- 4. Returned Inventory: 40 Grade-B wireless headphones
    -- 24 confirmed manufacturing defects (vendor-eligible), 16 cosmetic/user issues
    INSERT INTO public.returned_inventory (
        batch_id, product_id, return_tracking_id,
        returned_units, return_date, item_grade, return_reason,
        is_confirmed_defect, vendor_eligible_units, intake_status, notes
    ) VALUES (
        v_batch_id, v_prod_id, 'RET-HB09-2026' || v_test_suffix,
        40, CURRENT_DATE, 'Grade B', 'Repeated audio driver buzzing & connection drops',
        true, 24, 'inspected', 'Batch HB-09 repeated fault pattern detected during bench inspection'
    ) RETURNING id INTO v_return_id;

    -- ------------------------------------------------------------------
    -- TEST 1: VENDOR RETURN WINDOW & REMAINING DAYS
    -- ------------------------------------------------------------------
    PERFORM 1 FROM public.vw_vendor_compliance_and_rtv
    WHERE batch_id = v_batch_id 
      AND is_vendor_window_active = true 
      AND days_remaining_in_window = 20;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Vendor return window or remaining days incorrect!';
    END IF;
    RAISE NOTICE 'Test 1 PASSED: Vendor window is active with exactly 20 days remaining.';

    -- ------------------------------------------------------------------
    -- TEST 2: AUTOMATIC SUPPLIER QUALITY ALERT TRIGGER
    -- ------------------------------------------------------------------
    -- 24 defects out of 200 received = 12% defect rate (threshold is 5%). Critical alert expected.
    SELECT COUNT(*) INTO v_alert_count
    FROM public.supplier_quality_alerts
    WHERE batch_id = v_batch_id AND status = 'open';

    SELECT severity, defect_rate_pct INTO v_alert_rec
    FROM public.supplier_quality_alerts
    WHERE batch_id = v_batch_id AND status = 'open'
    LIMIT 1;

    IF v_alert_count <> 1 
       OR v_alert_rec.severity IS DISTINCT FROM 'critical' 
       OR v_alert_rec.defect_rate_pct IS DISTINCT FROM 12.00 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Expected 1 critical alert with 12.00%% defect rate. Found count: %, severity: %, rate: %',
            v_alert_count, v_alert_rec.severity, v_alert_rec.defect_rate_pct;
    END IF;
    RAISE NOTICE 'Test 2 PASSED: Supplier quality alert successfully triggered for Batch HB-09 (12.00%% defect rate vs 5.00%% threshold, severity: critical).';

    -- ------------------------------------------------------------------
    -- TEST 3: ROUTE COMPARISON ENGINE (fn_evaluate_recovery_options)
    -- ------------------------------------------------------------------
    -- 3A: Restock is INELIGIBLE (Grade B cannot be restocked directly)
    PERFORM 1 FROM public.fn_evaluate_recovery_options(v_return_id)
    WHERE route = 'restock' AND is_eligible = false;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST 3A FAILED: Restock should be ineligible for Grade B!';
    END IF;

    -- 3B: RTV route: 24 units eligible @ 60% of ₹1,400 = ₹840 unit credit (Total ₹20,160)
    SELECT potential_total_net_inr INTO v_calc_rtv_credit
    FROM public.fn_evaluate_recovery_options(v_return_id)
    WHERE route = 'return_to_vendor';
    IF v_calc_rtv_credit IS DISTINCT FROM 20160.00 THEN
        RAISE EXCEPTION 'TEST 3B FAILED: RTV credit mismatch! Expected 20160.00, got %', v_calc_rtv_credit;
    END IF;

    -- 3C: Refurbish route: Resale at 75% of ₹2,500 = ₹1,875. Cost = ₹250. Net = ₹1,625/unit.
    SELECT unit_net_recovery_inr INTO v_calc_refurb_net
    FROM public.fn_evaluate_recovery_options(v_return_id)
    WHERE route = 'refurbish_and_resell';
    IF v_calc_refurb_net IS DISTINCT FROM 1625.00 THEN
        RAISE EXCEPTION 'TEST 3C FAILED: Refurbish unit net mismatch! Expected 1625.00, got %', v_calc_refurb_net;
    END IF;
    RAISE NOTICE 'Test 3 PASSED: Route comparison engine validated (Restock blocked, RTV credit = ₹20,160, Refurb net/unit = ₹1,625).';

    -- ------------------------------------------------------------------
    -- TEST 4: BATCH SPLITTING & RECOVERY PLAN CREATION
    -- ------------------------------------------------------------------
    -- Create Plan Header
    INSERT INTO public.recovery_plans (
        returned_inventory_id, plan_code, status, manager_approved_by, manager_notes
    ) VALUES (
        v_return_id, 'PLAN-HB09-DEMO' || v_test_suffix, 'approved', 'Reverse Logistics Manager', 'Approved 24 units RTV and 16 units refurbishment'
    ) RETURNING id INTO v_plan_id;

    -- Allocation 1: 24 units to RTV (Supplier Credit)
    INSERT INTO public.recovery_allocations (
        plan_id, route, allocated_units, recovery_channel_type,
        unit_gross_recovery_inr, unit_cost_inr, estimated_days_to_realize,
        allocation_rationale
    ) VALUES (
        v_plan_id, 'return_to_vendor', 24, 'supplier_credit',
        840.00, 0.00, 14,
        'Claim 60% vendor credit under active 30-day warranty window for driver defect'
    );

    -- Allocation 2: 16 units to Refurbish & Resell (Cash Recovery)
    INSERT INTO public.recovery_allocations (
        plan_id, route, allocated_units, recovery_channel_type,
        unit_gross_recovery_inr, unit_cost_inr, estimated_days_to_realize,
        allocation_rationale
    ) VALUES (
        v_plan_id, 'refurbish_and_resell', 16, 'cash',
        1875.00, 250.00, 5,
        'Refurbish 16 units at ₹250 cost for resale at ₹1,875 to meet high customer demand'
    );

    RAISE NOTICE 'Test 4 PASSED: Batch split successfully across 24 units RTV and 16 units Refurbishment (Total = 40 units).';

    -- ------------------------------------------------------------------
    -- TEST 5: BATCH SPLITTING INTEGRITY (SINGLE & MULTI-PLAN REJECTION)
    -- ------------------------------------------------------------------
    -- 5A: Attempting to allocate an additional unit on the same plan (24 + 16 + 1 = 41 > 40)
    BEGIN
        INSERT INTO public.recovery_allocations (
            plan_id, route, allocated_units, recovery_channel_type,
            unit_gross_recovery_inr, unit_cost_inr, estimated_days_to_realize,
            allocation_rationale
        ) VALUES (
            v_plan_id, 'liquidation', 1, 'cash',
            490.00, 0.00, 3,
            'Attempted illegal over-allocation on same plan'
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Allocation violation%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 5A PASSED: Over-allocation on same plan properly blocked: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 5A FAILED: Expected allocation violation, got unexpected error: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5A FAILED: Trigger failed to reject over-allocation on same plan!';
    END IF;

    -- 5B: Attempting to allocate units via a SECOND plan for the same return record (Cross-Plan check)
    DECLARE
        v_second_plan_id UUID;
    BEGIN
        INSERT INTO public.recovery_plans (
            returned_inventory_id, plan_code, status, manager_approved_by, manager_notes
        ) VALUES (
            v_return_id, 'PLAN-HB09-SECOND' || v_test_suffix, 'draft', 'Assistant Manager', 'Attempted second parallel plan'
        ) RETURNING id INTO v_second_plan_id;

        INSERT INTO public.recovery_allocations (
            plan_id, route, allocated_units, recovery_channel_type,
            unit_gross_recovery_inr, unit_cost_inr, estimated_days_to_realize,
            allocation_rationale
        ) VALUES (
            v_second_plan_id, 'liquidation', 5, 'cash',
            490.00, 0.00, 3,
            'Attempted illegal over-allocation across plans'
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Allocation violation%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 5B PASSED: Cross-plan over-allocation properly blocked: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 5B FAILED: Expected allocation violation, got unexpected error: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5B FAILED: Trigger failed to reject cross-plan over-allocation!';
    END IF;

    -- 5C: Attempting to un-reject a plan when units are already fully allocated (Reactivation check)
    DECLARE
        v_rejected_plan_id UUID;
    BEGIN
        -- Create a plan initially in 'rejected' status
        INSERT INTO public.recovery_plans (
            returned_inventory_id, plan_code, status, manager_approved_by, manager_notes
        ) VALUES (
            v_return_id, 'PLAN-HB09-REJECTED' || v_test_suffix, 'rejected', 'Reviewer', 'Initially rejected proposal'
        ) RETURNING id INTO v_rejected_plan_id;

        -- Attach allocation of 10 units (allowed while rejected since units are unreserved)
        INSERT INTO public.recovery_allocations (
            plan_id, route, allocated_units, recovery_channel_type,
            unit_gross_recovery_inr, unit_cost_inr, estimated_days_to_realize,
            allocation_rationale
        ) VALUES (
            v_rejected_plan_id, 'liquidation', 10, 'cash',
            490.00, 0.00, 3,
            'Allocated while in rejected state'
        );

        -- Attempt to change status from 'rejected' back to 'approved' (Total would become 40 + 10 = 50 > 40)
        UPDATE public.recovery_plans
        SET status = 'approved'
        WHERE id = v_rejected_plan_id;

        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Plan reactivation violation%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 5C PASSED: Plan un-rejection/reactivation properly blocked: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 5C FAILED: Expected plan reactivation violation, got unexpected error: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5C FAILED: Trigger failed to reject reactivation of over-allocated rejected plan!';
    END IF;

    -- ------------------------------------------------------------------
    -- TEST 6: ZERO DOUBLE-COUNTING & EXECUTIVE SUMMARY VIEW
    -- Evaluates deltas from baseline to ensure correctness in populated databases
    -- ------------------------------------------------------------------
    SELECT
        net_cash_recovery_inr, net_supplier_credit_inr, total_combined_recovery_inr
    INTO
        v_pipeline_cash, v_pipeline_credit, v_pipeline_net
    FROM public.vw_recovery_pipeline_summary;

    -- Expected Delta Cash: 16 * ₹1,625 = ₹26,000.00
    -- Expected Delta Credit: 24 * ₹840 = ₹20,160.00
    -- Expected Delta Total: ₹46,160.00
    IF (v_pipeline_cash - v_base_pipeline_cash) <> 26000.00 
       OR (v_pipeline_credit - v_base_pipeline_credit) <> 20160.00 
       OR (v_pipeline_net - v_base_pipeline_net) <> 46160.00 THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Financial aggregation delta mismatch! Delta Cash: %, Delta Credit: %, Delta Net: %',
            (v_pipeline_cash - v_base_pipeline_cash),
            (v_pipeline_credit - v_base_pipeline_credit),
            (v_pipeline_net - v_base_pipeline_net);
    END IF;

    RAISE NOTICE 'Test 6 PASSED: Pipeline View accurately isolated Cash delta (₹26,000) and Credit delta (₹20,160) for Total Net delta of ₹46,160.';

    -- ------------------------------------------------------------------
    -- TEST 7: DYNAMIC QUALITY ALERT RECLASSIFICATION & AUTO-RESOLUTION
    -- ------------------------------------------------------------------
    -- Suppose an inspector reclassifies 20 of the defective units as customer remorse:
    -- Update is_confirmed_defect = false for those units (simulate by setting is_confirmed_defect on a separate record)
    -- Here, update returned_units with defect = false:
    UPDATE public.returned_inventory
    SET is_confirmed_defect = false
    WHERE id = v_return_id;

    -- Now confirmed defects = 0 / 200 = 0% < 5% threshold.
    -- The open alert should automatically transition to 'resolved'!
    SELECT COUNT(*) INTO v_alert_count
    FROM public.supplier_quality_alerts
    WHERE batch_id = v_batch_id AND status = 'resolved';

    IF v_alert_count <> 1 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: Alert failed to auto-resolve upon defect reclassification!';
    END IF;
    RAISE NOTICE 'Test 7 PASSED: Quality alert engine automatically resolved open alert upon defect reclassification.';

    RAISE NOTICE '=====================================================';
    RAISE NOTICE 'ALL 7 RETURNIQ VALIDATION TESTS PASSED WITH 100%% SUCCESS!';
    RAISE NOTICE '=====================================================';
END $$;

-- Guarantee 100% rollback of all test seed data
ROLLBACK;
