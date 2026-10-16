import { Router } from 'express';
import { getSupabaseClient, isSupabaseConfigured } from '../supabase.js';

const router = Router();
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_ROUTES = ['restock', 'refurbish_and_resell', 'return_to_vendor', 'liquidation', 'scrap_recycle'];
const ALLOWED_CHANNELS = ['cash', 'supplier_credit', 'none'];

/**
 * POST /api/plans
 * Submits a multi-route split recovery plan.
 *
 * TRANSACTION ATOMICITY:
 * Executes atomic PostgreSQL stored procedure fn_create_recovery_plan_with_allocations.
 * The plan header creation and all child route allocations execute inside a single
 * PostgreSQL transaction block.
 *
 * If any allocation is invalid or violates quota triggers (e.g. allocated units
 * exceed returned inventory or RTV units exceed vendor-eligible units), PostgreSQL
 * raises an exception and aborts the entire transaction. No orphaned plan headers
 * or partial allocations can persist.
 */
router.post('/', async (req, res, next) => {
  try {
    const { returned_inventory_id, plan_code, allocations } = req.body || {};

    // 1. Validation
    if (!returned_inventory_id || !UUID_REGEX.test(returned_inventory_id)) {
      return res.status(400).json({
        error: 'Validation error',
        details: "A valid UUID 'returned_inventory_id' is required.",
      });
    }

    if (!plan_code || typeof plan_code !== 'string' || plan_code.trim().length === 0) {
      return res.status(400).json({
        error: 'Validation error',
        details: "A non-empty string 'plan_code' is required.",
      });
    }

    if (!Array.isArray(allocations) || allocations.length === 0) {
      return res.status(400).json({
        error: 'Validation error',
        details: "'allocations' must be a non-empty array of allocation objects.",
      });
    }

    // Validate each allocation item and sanitize client input
    // DO NOT trust client-supplied totals (total_net_recovery_inr, etc.);
    // these are database-generated STORED columns calculated in PostgreSQL.
    const sanitizedAllocations = [];
    for (let i = 0; i < allocations.length; i++) {
      const item = allocations[i];

      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} must be a valid allocation object.`,
        });
      }

      if (!item.route || !ALLOWED_ROUTES.includes(item.route)) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} has invalid route '${item.route}'. Allowed: ${ALLOWED_ROUTES.join(', ')}.`,
        });
      }

      if (!Number.isInteger(item.allocated_units) || item.allocated_units <= 0) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} must have 'allocated_units' as a positive integer.`,
        });
      }

      if (!item.recovery_channel_type || !ALLOWED_CHANNELS.includes(item.recovery_channel_type)) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} has invalid recovery_channel_type '${item.recovery_channel_type}'. Allowed: ${ALLOWED_CHANNELS.join(', ')}.`,
        });
      }

      if (
        item.unit_gross_recovery_inr === undefined ||
        item.unit_gross_recovery_inr === null ||
        typeof item.unit_gross_recovery_inr === 'boolean' ||
        (typeof item.unit_gross_recovery_inr === 'string' && item.unit_gross_recovery_inr.trim() === '')
      ) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} must specify a valid, non-null 'unit_gross_recovery_inr'.`,
        });
      }

      const gross = Number(item.unit_gross_recovery_inr);
      if (!Number.isFinite(gross) || gross < 0) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} must specify a finite, non-negative numeric 'unit_gross_recovery_inr'.`,
        });
      }

      if (typeof item.unit_cost_inr === 'boolean' || Array.isArray(item.unit_cost_inr)) {
        return res.status(400).json({
          error: 'Validation error',
          details: `Allocation at index ${i} has invalid 'unit_cost_inr'.`,
        });
      }

      let cost = 0;
      if (
        item.unit_cost_inr !== undefined &&
        item.unit_cost_inr !== null &&
        !(typeof item.unit_cost_inr === 'string' && item.unit_cost_inr.trim() === '')
      ) {
        cost = Number(item.unit_cost_inr);
        if (!Number.isFinite(cost) || cost < 0) {
          return res.status(400).json({
            error: 'Validation error',
            details: `Allocation at index ${i} must specify a finite, non-negative numeric 'unit_cost_inr'.`,
          });
        }
      }

      sanitizedAllocations.push({
        route: item.route,
        allocated_units: item.allocated_units,
        recovery_channel_type: item.recovery_channel_type,
        unit_gross_recovery_inr: gross,
        unit_cost_inr: cost,
        estimated_days_to_realize: Math.max(0, parseInt(item.estimated_days_to_realize || 0, 10)),
        allocation_rationale: item.allocation_rationale ? String(item.allocation_rationale).trim() : 'Standard recovery allocation',
      });
    }

    if (!isSupabaseConfigured()) {
      return res.status(503).json({
        error: 'Database service unavailable',
        message: 'Supabase connection is not configured. Please set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in your local .env file.',
      });
    }

    const supabase = getSupabaseClient();

    // Execute atomic PostgreSQL stored procedure (single transaction block)
    const { data, error } = await supabase.rpc('fn_create_recovery_plan_with_allocations', {
      p_returned_inventory_id: returned_inventory_id,
      p_plan_code: plan_code.trim(),
      p_allocations: sanitizedAllocations,
    });

    if (error) {
      return res.status(400).json({
        error: 'Plan creation failed',
        details: error.message,
      });
    }

    return res.status(201).json({
      plan: data?.plan || null,
      allocations: data?.allocations || [],
    });
  } catch (err) {
    next(err);
  }
});

/**
 * PATCH /api/plans/:id
 * Approves or rejects an existing recovery plan.
 *
 * CRITICAL AUTHORIZATION NOTICE:
 * 1. 'manager_approved_by' is an informational audit label from request body;
 *    it is NEVER proof of caller identity or authorization.
 * 2. Query parameters, request body strings, or custom headers (e.g. 'x-demo-role')
 *    MUST NOT be treated as authentication or authorization.
 * 3. In this local prototype, caller identity is unverified.
 *    BEFORE PUBLIC OR PRODUCTION DEPLOYMENT:
 *    This route MUST be protected by real server-side authentication and authorization
 *    middleware (e.g., verifying a verified Supabase Auth JWT / auth.uid() and ensuring
 *    the authenticated user holds an authorized Operations Manager role).
 *
 * Timestamps: Always generated server-side (new Date().toISOString()); never trusts client timestamps.
 */
router.patch('/:id', async (req, res, next) => {
  try {
    const { id } = req.params;
    const { status, manager_approved_by, manager_notes } = req.body || {};

    if (!id || !UUID_REGEX.test(id)) {
      return res.status(400).json({
        error: 'Validation error',
        details: 'A valid UUID plan parameter is required in the path.',
      });
    }

    if (!status || !['approved', 'rejected'].includes(status)) {
      return res.status(400).json({
        error: 'Validation error',
        details: "Field 'status' must be either 'approved' or 'rejected'.",
      });
    }

    if (status === 'approved' && (!manager_approved_by || typeof manager_approved_by !== 'string' || manager_approved_by.trim().length === 0)) {
      return res.status(400).json({
        error: 'Validation error',
        details: "Approving a plan requires 'manager_approved_by' identifier.",
      });
    }

    if (!isSupabaseConfigured()) {
      return res.status(503).json({
        error: 'Database service unavailable',
        message: 'Supabase connection is not configured. Please set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in your local .env file.',
      });
    }

    const supabase = getSupabaseClient();

    // Enforce server-side timestamp; ignore any client-supplied approved_at
    const updatePayload = {
      status,
      manager_approved_by: status === 'approved' ? manager_approved_by.trim() : null,
      manager_notes: manager_notes ? String(manager_notes).trim() : null,
      approved_at: status === 'approved' ? new Date().toISOString() : null,
    };

    const { data, error } = await supabase
      .from('recovery_plans')
      .update(updatePayload)
      .eq('id', id)
      .select()
      .single();

    if (error) {
      return res.status(400).json({
        error: 'Plan update failed',
        details: error.message,
      });
    }

    if (!data) {
      return res.status(404).json({
        error: 'Not found',
        details: `Recovery plan '${id}' not found.`,
      });
    }

    return res.status(200).json(data);
  } catch (err) {
    next(err);
  }
});

export default router;
