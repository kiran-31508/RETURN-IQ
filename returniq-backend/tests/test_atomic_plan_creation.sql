-- ==============================================================================
-- ReturnIQ Test Suite: Atomic Recovery Plan Creation & Rollback Integrity
-- File: tests/test_atomic_plan_creation.sql
-- Description:
--   Automated verification of the atomic stored procedure:
--   fn_create_recovery_plan_with_allocations(p_returned_inventory_id, p_plan_code, p_allocations)
--
-- Tests Covered:
--   1. Happy Path: Creates plan header ('pending_approval') and child allocations atomically.
--   2. Integrity: Database-generated STORED columns calculated correctly without trusting client numbers.
--   3. Rollback on Over-Allocation: Total allocated units exceeding returned units rolls back entire plan.
--   4. Rollback on RTV Limit: RTV units exceeding vendor-eligible units rolls back entire plan.
--   5. Rollback on Duplicate Plan Code: Unique constraint violation aborts transaction safely.
--   6. Validation Errors (Isolated on fresh return lot to prevent quota interference):
--      6A. Invalid route rejection with exact error inspection.
--      6B. Non-positive unit counts (0 and negative) rejection.
--      6C. Fractional unit counts ("12.5") rejection.
--      6D. Missing and null gross recovery amounts rejection.
--      6E. Negative gross recovery amounts rejection.
--      6F. Invalid recovery channel type rejection.
--   7. Rollback on Non-existent Return Record.
-- ==============================================================================

BEGIN;

DO $$
DECLARE
    v_sup_id UUID;
    v_prod_id UUID;
    v_batch_id UUID;
    v_return_id UUID;
    v_second_ret_id UUID;
    v_val_ret_id UUID;
    v_result JSONB;
    v_plan_id UUID;
    v_plan_count INT;
    v_alloc_count INT;
    v_gross_1 NUMERIC(12, 2);
    v_net_2 NUMERIC(12, 2);
    v_error_caught BOOLEAN := false;
BEGIN
    RAISE NOTICE '=====================================================';
    RAISE NOTICE 'Starting Atomic Plan Creation Test Suite...';
    RAISE NOTICE '=====================================================';

    -- ------------------------------------------------------------------
    -- SETUP: Seed Test Catalog, Batch, and Return Records
    -- ------------------------------------------------------------------
    INSERT INTO public.suppliers (name, code, contact_email, default_return_window_days, default_credit_rate_pct)
    VALUES ('Apex Audio Innovations', 'SUP-APEX-01', 'ops@apexaudio.com', 30, 60.00)
    RETURNING id INTO v_sup_id;

    INSERT INTO public.products (
        supplier_id, sku, name, category,
        cost_price_inr, mrp_inr, current_inventory_units, total_units_sold, daily_demand_velocity,
        refurb_cost_inr, refurb_turnaround_days, resale_price_pct_of_mrp, liquidation_rate_pct_of_cost
    ) VALUES (
        v_sup_id, 'AP-PRO-300', 'Apex Pro Wireless ANC', 'Audio',
        1000.00, 2000.00, 50, 500, 10.00,
        200.00, 5, 75.00, 30.00
    ) RETURNING id INTO v_prod_id;

    INSERT INTO public.supplier_batches (
        supplier_id, product_id, batch_code,
        received_date, vendor_window_basis_date, vendor_return_deadline,
        units_received, custom_credit_rate_pct, defect_threshold_pct, min_sample_size_for_alert
    ) VALUES (
        v_sup_id, v_prod_id, 'BATCH-APEX-01',
        CURRENT_DATE - INTERVAL '5 days',
        CURRENT_DATE - INTERVAL '5 days',
        CURRENT_DATE + INTERVAL '25 days',
        200, 60.00, 5.00, 10
    ) RETURNING id INTO v_batch_id;

    -- Return Record 1 (Happy Path & Multi-Plan RTV check): 40 units returned, 24 vendor-eligible
    INSERT INTO public.returned_inventory (
        batch_id, product_id, return_tracking_id,
        returned_units, return_date, item_grade, return_reason,
        is_confirmed_defect, vendor_eligible_units, intake_status, notes
    ) VALUES (
        v_batch_id, v_prod_id, 'RET-ATOMIC-TEST-01',
        40, CURRENT_DATE, 'Grade B', 'Microphone crackle and cosmetic scuffs',
        true, 24, 'inspected', 'Intake batch for atomic RPC verification'
    ) RETURNING id INTO v_return_id;

    -- Return Record 2 (Over-allocation test): 20 units returned, 10 vendor-eligible
    INSERT INTO public.returned_inventory (
        batch_id, product_id, return_tracking_id,
        returned_units, return_date, item_grade, return_reason,
        is_confirmed_defect, vendor_eligible_units, intake_status, notes
    ) VALUES (
        v_batch_id, v_prod_id, 'RET-ATOMIC-TEST-02',
        20, CURRENT_DATE, 'Grade B', 'Defective audio drivers',
        true, 10, 'inspected', 'Second return lot for quota checks'
    ) RETURNING id INTO v_second_ret_id;

    -- Return Record 3 (Dedicated for input validation tests, plenty of capacity): 100 units returned
    INSERT INTO public.returned_inventory (
        batch_id, product_id, return_tracking_id,
        returned_units, return_date, item_grade, return_reason,
        is_confirmed_defect, vendor_eligible_units, intake_status, notes
    ) VALUES (
        v_batch_id, v_prod_id, 'RET-ATOMIC-TEST-03',
        100, CURRENT_DATE, 'Grade B', 'Inspection batch for validation tests',
        true, 50, 'inspected', 'Dedicated return lot for isolated validation error checks'
    ) RETURNING id INTO v_val_ret_id;

    -- ------------------------------------------------------------------
    -- TEST 1: SUCCESSFUL ATOMIC PLAN CREATION
    -- ------------------------------------------------------------------
    -- Plan: 24 units RTV (supplier_credit) + 16 units Refurbish (cash) = 40 units
    v_result := public.fn_create_recovery_plan_with_allocations(
        v_return_id,
        'PLAN-ATOMIC-SUCCESS-01',
        '[
            {
                "route": "return_to_vendor",
                "allocated_units": 24,
                "recovery_channel_type": "supplier_credit",
                "unit_gross_recovery_inr": 600.00,
                "unit_cost_inr": 0.00,
                "estimated_days_to_realize": 14,
                "allocation_rationale": "Claim 60% vendor warranty credit"
            },
            {
                "route": "refurbish_and_resell",
                "allocated_units": 16,
                "recovery_channel_type": "cash",
                "unit_gross_recovery_inr": 1500.00,
                "unit_cost_inr": 200.00,
                "estimated_days_to_realize": 5,
                "allocation_rationale": "Refurbish 16 units for secondary market resale"
            }
        ]'::jsonb
    );

    IF v_result IS NULL OR v_result->'plan' IS NULL OR v_result->'allocations' IS NULL THEN
        RAISE EXCEPTION 'TEST 1 FAILED: RPC did not return expected composite JSON structure!';
    END IF;

    v_plan_id := (v_result->'plan'->>'id')::UUID;

    -- Assert plan header state in database
    SELECT COUNT(*) INTO v_plan_count
    FROM public.recovery_plans
    WHERE id = v_plan_id AND plan_code = 'PLAN-ATOMIC-SUCCESS-01' AND status = 'pending_approval';

    IF v_plan_count <> 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Plan header not found in pending_approval status!';
    END IF;

    -- Assert allocations count
    SELECT COUNT(*) INTO v_alloc_count
    FROM public.recovery_allocations
    WHERE plan_id = v_plan_id;

    IF v_alloc_count <> 2 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Expected 2 allocations in database, found %!', v_alloc_count;
    END IF;

    -- Assert database-generated stored columns
    SELECT total_gross_recovery_inr INTO v_gross_1
    FROM public.recovery_allocations
    WHERE plan_id = v_plan_id AND route = 'return_to_vendor';

    -- 24 units * ₹600.00 = ₹14,400.00
    IF v_gross_1 <> 14400.00 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Stored column total_gross_recovery_inr incorrect! Expected 14400.00, got %', v_gross_1;
    END IF;

    SELECT total_net_recovery_inr INTO v_net_2
    FROM public.recovery_allocations
    WHERE plan_id = v_plan_id AND route = 'refurbish_and_resell';

    -- 16 units * (₹1,500.00 - ₹200.00) = ₹20,800.00
    IF v_net_2 <> 20800.00 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Stored column total_net_recovery_inr incorrect! Expected 20800.00, got %', v_net_2;
    END IF;

    RAISE NOTICE 'Test 1 PASSED: Happy path atomic plan creation and stored calculations validated.';

    -- ------------------------------------------------------------------
    -- TEST 2: ATOMIC ROLLBACK ON OVER-ALLOCATION (Quota > returned_units)
    -- ------------------------------------------------------------------
    -- Second return has 20 units. Attempt to allocate 15 + 10 = 25 units.
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_second_ret_id,
            'PLAN-FAIL-OVERALLOC',
            '[
                {
                    "route": "refurbish_and_resell",
                    "allocated_units": 15,
                    "recovery_channel_type": "cash",
                    "unit_gross_recovery_inr": 1500.00,
                    "unit_cost_inr": 200.00,
                    "estimated_days_to_realize": 5,
                    "allocation_rationale": "Over-allocation part 1"
                },
                {
                    "route": "liquidation",
                    "allocated_units": 10,
                    "recovery_channel_type": "cash",
                    "unit_gross_recovery_inr": 300.00,
                    "unit_cost_inr": 0.00,
                    "estimated_days_to_realize": 3,
                    "allocation_rationale": "Over-allocation part 2"
                }
            ]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Allocation violation%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 2 caught expected allocation violation: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 2 FAILED: Expected allocation violation, got unexpected error: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Over-allocation was not rejected by database trigger!';
    END IF;

    -- CRITICAL ATOMICITY CHECK: Confirm that the plan header was completely rolled back!
    SELECT COUNT(*) INTO v_plan_count
    FROM public.recovery_plans
    WHERE plan_code = 'PLAN-FAIL-OVERALLOC';

    IF v_plan_count <> 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: ATOMICITY VIOLATION! Orphaned plan header exists in recovery_plans!';
    END IF;

    SELECT COUNT(*) INTO v_alloc_count
    FROM public.recovery_allocations ra
    JOIN public.recovery_plans rp ON rp.id = ra.plan_id
    WHERE rp.plan_code = 'PLAN-FAIL-OVERALLOC';

    IF v_alloc_count <> 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Partial allocations leaked into database!';
    END IF;

    RAISE NOTICE 'Test 2 PASSED: Over-allocation rejected and rolled back atomically (0 orphaned headers, 0 allocations).';

    -- ------------------------------------------------------------------
    -- TEST 3: ATOMIC ROLLBACK ON RTV LIMIT (Allocated RTV > vendor_eligible_units)
    -- ------------------------------------------------------------------
    -- Uses v_val_ret_id (100 returned units, 50 vendor-eligible units).
    -- Attempting 55 RTV units satisfies total returned capacity (55 <= 100)
    -- but specifically violates vendor warranty quota (55 > 50).
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-RTV',
            '[
                {
                    "route": "return_to_vendor",
                    "allocated_units": 55,
                    "recovery_channel_type": "supplier_credit",
                    "unit_gross_recovery_inr": 600.00,
                    "unit_cost_inr": 0.00,
                    "estimated_days_to_realize": 14,
                    "allocation_rationale": "Illegal excess RTV claim exceeding vendor-eligible quota"
                }
            ]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Vendor claim violation%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 3 caught expected RTV violation: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 3 FAILED: Expected vendor claim violation, got unexpected error: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Excess RTV claim was not rejected!';
    END IF;

    -- Confirm plan header was completely rolled back
    SELECT COUNT(*) INTO v_plan_count
    FROM public.recovery_plans
    WHERE plan_code = 'PLAN-FAIL-RTV';

    IF v_plan_count <> 0 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: ATOMICITY VIOLATION! Plan header was committed despite trigger failure!';
    END IF;

    -- Confirm allocation rows were completely rolled back
    SELECT COUNT(*) INTO v_alloc_count
    FROM public.recovery_allocations ra
    JOIN public.recovery_plans rp ON rp.id = ra.plan_id
    WHERE rp.plan_code = 'PLAN-FAIL-RTV';

    IF v_alloc_count <> 0 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Partial allocations leaked into database!';
    END IF;

    RAISE NOTICE 'Test 3 PASSED: Excess RTV claim rejected and rolled back atomically (0 orphaned headers, 0 allocations).';

    -- ------------------------------------------------------------------
    -- TEST 4: ATOMIC ROLLBACK ON DUPLICATE PLAN CODE
    -- ------------------------------------------------------------------
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_second_ret_id,
            'PLAN-ATOMIC-SUCCESS-01', -- already created in Test 1
            '[
                {
                    "route": "liquidation",
                    "allocated_units": 1,
                    "recovery_channel_type": "cash",
                    "unit_gross_recovery_inr": 300.00,
                    "unit_cost_inr": 0.00,
                    "estimated_days_to_realize": 3,
                    "allocation_rationale": "Duplicate code test"
                }
            ]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%already exists%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 4 caught expected duplicate plan code error: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 4 FAILED: Expected duplicate plan code error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Duplicate plan code was not rejected!';
    END IF;

    RAISE NOTICE 'Test 4 PASSED: Duplicate plan code rejected gracefully.';

    -- ------------------------------------------------------------------
    -- TEST 5: ISOLATED VALIDATION ERROR CHECKS (Using v_val_ret_id to rule out quota interference)
    -- ------------------------------------------------------------------

    -- 5A: Invalid route name
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-ROUTE',
            '[{"route":"invalid_route","allocated_units":5,"recovery_channel_type":"cash","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Invalid allocation route%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5A FAILED: Expected route error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5A FAILED: Invalid route was not rejected!';
    END IF;

    -- 5B: Non-positive unit count (Zero units)
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-ZERO-UNITS',
            '[{"route":"liquidation","allocated_units":0,"recovery_channel_type":"cash","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%allocated_units must be a positive integer%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5B (Zero) FAILED: Expected positive integer error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5B (Zero) FAILED: Zero units were not rejected!';
    END IF;

    -- 5B (Negative units)
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-NEG-UNITS',
            '[{"route":"liquidation","allocated_units":-5,"recovery_channel_type":"cash","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%allocated_units must be a positive integer%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5B (Negative) FAILED: Expected positive integer error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5B (Negative) FAILED: Negative units were not rejected!';
    END IF;

    -- 5C: Fractional unit count ("12.5")
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-FRAC-UNITS',
            '[{"route":"liquidation","allocated_units":"12.5","recovery_channel_type":"cash","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%allocated_units must be a valid integer%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5C FAILED: Expected integer validation error for fraction, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5C FAILED: Fractional units were not rejected!';
    END IF;

    -- 5D: Missing gross recovery amount
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-MISSING-GROSS',
            '[{"route":"liquidation","allocated_units":5,"recovery_channel_type":"cash"}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%unit_gross_recovery_inr is required%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5D (Missing) FAILED: Expected gross recovery required error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5D (Missing) FAILED: Missing gross recovery was not rejected!';
    END IF;

    -- 5D: Explicit JSON null gross recovery amount
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-NULL-GROSS',
            '[{"route":"liquidation","allocated_units":5,"recovery_channel_type":"cash","unit_gross_recovery_inr":null}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%unit_gross_recovery_inr is required%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5D (Null) FAILED: Expected gross recovery required error for null, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5D (Null) FAILED: Null gross recovery was not rejected!';
    END IF;

    -- 5E: Negative gross recovery amount
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-NEG-GROSS',
            '[{"route":"liquidation","allocated_units":5,"recovery_channel_type":"cash","unit_gross_recovery_inr":-10.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%unit_gross_recovery_inr cannot be negative%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5E FAILED: Expected non-negative gross error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5E FAILED: Negative gross recovery was not rejected!';
    END IF;

    -- 5F: Invalid recovery channel
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            v_val_ret_id,
            'PLAN-FAIL-CHANNEL',
            '[{"route":"liquidation","allocated_units":5,"recovery_channel_type":"unsupported_channel","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%Invalid recovery_channel_type%' THEN
            v_error_caught := true;
        ELSE
            RAISE EXCEPTION 'TEST 5F FAILED: Expected channel error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 5F FAILED: Invalid recovery channel was not rejected!';
    END IF;

    -- Verify 0 plan headers and 0 allocations leaked from any Test 5 validation failure
    SELECT COUNT(*) INTO v_plan_count
    FROM public.recovery_plans
    WHERE plan_code IN (
        'PLAN-FAIL-ROUTE', 'PLAN-FAIL-ZERO-UNITS', 'PLAN-FAIL-NEG-UNITS',
        'PLAN-FAIL-FRAC-UNITS', 'PLAN-FAIL-MISSING-GROSS', 'PLAN-FAIL-NULL-GROSS',
        'PLAN-FAIL-NEG-GROSS', 'PLAN-FAIL-CHANNEL'
    );

    IF v_plan_count <> 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Plan headers leaked from validation failure attempts! Found: %', v_plan_count;
    END IF;

    RAISE NOTICE 'Test 5 PASSED: All validation error branches rejected with exact error messages and zero orphaned records.';

    -- ------------------------------------------------------------------
    -- TEST 6: NON-EXISTENT RETURN RECORD REJECTION
    -- ------------------------------------------------------------------
    BEGIN
        v_result := public.fn_create_recovery_plan_with_allocations(
            '00000000-0000-0000-0000-000000000000'::UUID,
            'PLAN-FAIL-NO-RETURN',
            '[{"route":"liquidation","allocated_units":1,"recovery_channel_type":"cash","unit_gross_recovery_inr":100.00}]'::jsonb
        );
        v_error_caught := false;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%does not exist%' THEN
            v_error_caught := true;
            RAISE NOTICE 'Test 6 caught expected non-existent record error: "%"', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 6 FAILED: Expected non-existent return error, got: "%"', SQLERRM;
        END IF;
    END;

    IF NOT v_error_caught THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Non-existent return ID was not rejected!';
    END IF;

    SELECT COUNT(*) INTO v_plan_count
    FROM public.recovery_plans
    WHERE plan_code = 'PLAN-FAIL-NO-RETURN';

    IF v_plan_count <> 0 THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Plan header leaked for non-existent return record!';
    END IF;

    RAISE NOTICE 'Test 6 PASSED: Non-existent return record rejected cleanly.';

    RAISE NOTICE '=====================================================';
    RAISE NOTICE 'ALL ATOMIC RPC PLAN CREATION & VALIDATION TESTS PASSED!';
    RAISE NOTICE '=====================================================';
END $$;

ROLLBACK;
