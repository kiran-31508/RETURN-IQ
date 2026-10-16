import { Router } from 'express';
import { getSupabaseClient, isSupabaseConfigured } from '../supabase.js';
import { evaluateLiveReturn } from '../services/recoveryEngine.js';

const router = Router();
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * POST /api/routes/evaluate
 * Evaluates the 4 recovery pathways (Restock, RTV, Refurbish, Liquidation).
 * Queries live Supabase gb_* tables when available, with explicit dataset fallback tagging.
 */
router.post('/', async (req, res, next) => {
  try {
    const returnId = req.body?.return_id || req.body?.p_return_id;

    if (!returnId || typeof returnId !== 'string' || !returnId.trim()) {
      return res.status(400).json({
        error: 'Validation error',
        details: "A valid 'return_id' or 'p_return_id' string is required in request body.",
      });
    }

    const trimmedId = returnId.trim();
    const supabase = isSupabaseConfigured() ? getSupabaseClient() : null;

    // 1. If it's a UUID and database is configured, evaluate via database RPC
    if (UUID_REGEX.test(trimmedId) && supabase) {
      try {
        const { data, error } = await supabase.rpc('fn_evaluate_recovery_options', {
          p_return_id: trimmedId,
        });

        if (!error && data && data.length > 0) {
          return res.status(200).json(data);
        }
      } catch (err) {
        // Fall through to evaluateLiveReturn
      }
    }

    // 2. Query live Supabase gb_* tables or labeled fallback
    const liveEval = await evaluateLiveReturn(supabase, trimmedId);
    if (liveEval && liveEval.routes && liveEval.routes.length > 0) {
      res.setHeader('X-Data-Source', liveEval.dataSource);
      res.setHeader('X-Database-Backed', String(liveEval.isDatabaseBacked));
      return res.status(200).json(liveEval.routes);
    }

    return res.status(404).json({
      error: 'Not found',
      details: `No returned inventory record found with ID '${trimmedId}'.`,
    });
  } catch (err) {
    next(err);
  }
});

export default router;
