-- ==============================================================================
-- Migration: 20261009000004_atomic_recovery_plan_creation_rpc.sql
-- Description:
--   Creates an atomic stored procedure (RPC) for recovery plan and allocation creation.
--   Replaces the application-level compensating-deletion pattern in Express
--   with a single database transaction block.
--
-- Safety:
--   Non-destructive corrective migration: does not drop tables or alter existing schema.
--   Preserves all existing triggers (trg_validate_recovery_allocation).
--   If any allocation fails or violates allocation constraints, the entire
--   operation (including the plan header) is rolled back atomically by PostgreSQL.
--   Sets search_path = '' and uses schema-qualified public objects.
--   Restricts execution to service_role.
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.fn_create_recovery_plan_with_allocations(
    p_returned_inventory_id UUID,
    p_plan_code TEXT,
    p_allocations JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_clean_code TEXT;
    v_plan public.recovery_plans%ROWTYPE;
    v_inserted_allocations JSONB;
    v_elem JSONB;
    v_route VARCHAR(30);
    v_units INT;
    v_channel VARCHAR(20);
    v_gross NUMERIC(12, 2);
    v_cost NUMERIC(12, 2);
    v_days INT;
    v_ret_exists BOOLEAN;
BEGIN
    -- 1. Validate returned_inventory existence
    IF p_returned_inventory_id IS NULL THEN
        RAISE EXCEPTION 'returned_inventory_id is required';
    END IF;

    SELECT EXISTS(SELECT 1 FROM public.returned_inventory WHERE id = p_returned_inventory_id)
    INTO v_ret_exists;

    IF NOT v_ret_exists THEN
        RAISE EXCEPTION 'Returned inventory record with ID "%" does not exist', p_returned_inventory_id;
    END IF;

    -- 2. Validate plan_code
    v_clean_code := TRIM(p_plan_code);
    IF v_clean_code IS NULL OR v_clean_code = '' THEN
        RAISE EXCEPTION 'plan_code cannot be empty';
    END IF;

    IF EXISTS(SELECT 1 FROM public.recovery_plans WHERE plan_code = v_clean_code) THEN
        RAISE EXCEPTION 'Recovery plan with code "%" already exists', v_clean_code;
    END IF;

    -- 3. Validate p_allocations JSON array structure
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'allocations must be a non-empty JSON array';
    END IF;

    -- 4. Deep-validate every allocation element before insertion
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
        -- Route validation
        v_route := v_elem->>'route';
        IF v_route IS NULL OR v_route NOT IN ('restock', 'refurbish_and_resell', 'return_to_vendor', 'liquidation', 'scrap_recycle') THEN
            RAISE EXCEPTION 'Invalid allocation route: "%". Allowed routes: restock, refurbish_and_resell, return_to_vendor, liquidation, scrap_recycle', v_route;
        END IF;

        -- Allocated units validation (required, integer, positive, no fractions)
        IF (v_elem->>'allocated_units') IS NULL THEN
            RAISE EXCEPTION 'allocated_units is required for all allocations';
        END IF;

        BEGIN
            v_units := (v_elem->>'allocated_units')::INT;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'allocated_units must be a valid integer';
        END;

        IF v_units <= 0 THEN
            RAISE EXCEPTION 'allocated_units must be a positive integer, got: %', v_units;
        END IF;

        -- Recovery channel type validation
        v_channel := v_elem->>'recovery_channel_type';
        IF v_channel IS NULL OR v_channel NOT IN ('cash', 'supplier_credit', 'none') THEN
            RAISE EXCEPTION 'Invalid recovery_channel_type: "%". Allowed: cash, supplier_credit, none', v_channel;
        END IF;

        -- Gross recovery validation (strictly required, not null, valid numeric, non-negative)
        IF (v_elem->>'unit_gross_recovery_inr') IS NULL THEN
            RAISE EXCEPTION 'unit_gross_recovery_inr is required for all allocations';
        END IF;

        BEGIN
            v_gross := (v_elem->>'unit_gross_recovery_inr')::NUMERIC;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'unit_gross_recovery_inr must be a valid numeric amount';
        END;

        IF v_gross < 0 THEN
            RAISE EXCEPTION 'unit_gross_recovery_inr cannot be negative, got: %', v_gross;
        END IF;

        -- Cost validation (optional, defaults to 0.00, non-negative)
        BEGIN
            v_cost := COALESCE((v_elem->>'unit_cost_inr')::NUMERIC, 0.00);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'unit_cost_inr must be a valid numeric amount';
        END;

        IF v_cost < 0 THEN
            RAISE EXCEPTION 'unit_cost_inr cannot be negative, got: %', v_cost;
        END IF;

        -- Realization days validation (optional, defaults to 0, non-negative)
        BEGIN
            v_days := COALESCE((v_elem->>'estimated_days_to_realize')::INT, 0);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'estimated_days_to_realize must be a valid integer';
        END;

        IF v_days < 0 THEN
            RAISE EXCEPTION 'estimated_days_to_realize cannot be negative, got: %', v_days;
        END IF;
    END LOOP;

    -- 5. Insert Plan Header in 'pending_approval' status
    INSERT INTO public.recovery_plans (
        returned_inventory_id, plan_code, status
    ) VALUES (
        p_returned_inventory_id, v_clean_code, 'pending_approval'
    ) RETURNING * INTO v_plan;

    -- 6. Insert All Child Allocations
    -- Trigger trg_validate_recovery_allocation fires on each row.
    -- Any quota violation (total units > returned_units or RTV units > vendor_eligible_units)
    -- triggers an immediate exception, which automatically rolls back the entire function call
    -- including the plan header created in Step 5.
    INSERT INTO public.recovery_allocations (
        plan_id,
        route,
        allocated_units,
        recovery_channel_type,
        unit_gross_recovery_inr,
        unit_cost_inr,
        estimated_days_to_realize,
        allocation_rationale
    )
    SELECT
        v_plan.id,
        (elem->>'route')::VARCHAR,
        (elem->>'allocated_units')::INT,
        (elem->>'recovery_channel_type')::VARCHAR,
        (elem->>'unit_gross_recovery_inr')::NUMERIC,
        COALESCE((elem->>'unit_cost_inr')::NUMERIC, 0.00),
        GREATEST(0, COALESCE((elem->>'estimated_days_to_realize')::INT, 0)),
        COALESCE(NULLIF(TRIM(elem->>'allocation_rationale'), ''), 'Standard recovery allocation')
    FROM jsonb_array_elements(p_allocations) AS elem;

    -- 7. Query inserted allocations from the concrete table
    -- Guarantees inclusion of database-generated stored columns (total_gross_recovery_inr,
    -- total_cost_inr, total_net_recovery_inr) with deterministic ordering.
    SELECT COALESCE(jsonb_agg(to_jsonb(ra) ORDER BY ra.created_at ASC, ra.id ASC), '[]'::jsonb)
    INTO v_inserted_allocations
    FROM public.recovery_allocations ra
    WHERE ra.plan_id = v_plan.id;

    -- 8. Build composite result matching API contract
    RETURN jsonb_build_object(
        'plan', to_jsonb(v_plan),
        'allocations', v_inserted_allocations
    );
END;
$$;

-- 9. Function Execution Permissions Hardening
-- Revoke execution from PUBLIC, anon, and authenticated roles.
REVOKE EXECUTE ON FUNCTION public.fn_create_recovery_plan_with_allocations(UUID, TEXT, JSONB) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE EXECUTE ON FUNCTION public.fn_create_recovery_plan_with_allocations(UUID, TEXT, JSONB) FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'REVOKE EXECUTE ON FUNCTION public.fn_create_recovery_plan_with_allocations(UUID, TEXT, JSONB) FROM authenticated';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.fn_create_recovery_plan_with_allocations(UUID, TEXT, JSONB) TO service_role';
    END IF;
END $$;
