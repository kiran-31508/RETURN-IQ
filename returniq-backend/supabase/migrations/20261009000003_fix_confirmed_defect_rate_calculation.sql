-- ==============================================================================
-- Migration: 20261009000003_fix_confirmed_defect_rate_calculation.sql
-- Description:
--   Corrective patch for defect-rate calculation.
--   Updates fn_recalculate_batch_quality_alert and dependent analytics views
--   (vw_vendor_compliance_and_rtv, vw_product_demand_and_inventory) to aggregate
--   vendor_eligible_units instead of returned_units for confirmed defect rows.
--
-- Safety:
--   Non-destructive patch: does not drop tables, truncate data, or alter schemas.
--   Uses CREATE OR REPLACE for existing function and views.
--   Re-synchronizes any open alerts to rectify previously inflated defect rates.
-- ==============================================================================

-- 1. UPDATE DYNAMIC QUALITY ALERT ENGINE FUNCTION
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

    -- Count confirmed defects using vendor_eligible_units (ignoring buyer remorse or cosmetic-only returns)
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

-- 2. UPDATE VIEW 1: VENDOR COMPLIANCE, QUALITY & EXPLICIT RETURN WINDOW TRACKING
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

-- 3. UPDATE VIEW 3: PRODUCT INVENTORY, DEMAND VELOCITY & DEFECT OVERVIEW
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

-- 4. RE-SYNCHRONIZE EXISTING OPEN ALERTS
-- Re-evaluate all open alerts across batches to correct any previously inflated defect rates
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT DISTINCT batch_id FROM public.supplier_quality_alerts WHERE status = 'open' LOOP
        PERFORM public.fn_recalculate_batch_quality_alert(r.batch_id);
    END LOOP;
END $$;
