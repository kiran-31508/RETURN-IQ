import { Router } from 'express';
import { getSupabaseClient, isSupabaseConfigured } from '../supabase.js';
import { fetchLiveReturns, getReturnById, getSupplierQualityAnalytics } from '../services/recoveryEngine.js';

const router = Router();

/**
 * GET /api/returns
 * Fetches returned inventory records joined with product & batch details,
 * and lists open supplier quality alerts.
 * Queries Supabase gb_returns when available; explicitly labels fallback when pending migration.
 */
router.get('/', async (req, res, next) => {
  try {
    const supabase = isSupabaseConfigured() ? getSupabaseClient() : null;
    const isLegacyRequested = req.query.source === 'legacy' || req.query.dataset === 'legacy';
    const isCombinedRequested = req.query.include_legacy === 'true' || req.query.combined === 'true';

    // If caller specifically requested legacy records from returned_inventory
    if (isLegacyRequested) {
      let legacyReturns = [];
      let dbAlerts = [];

      if (supabase) {
        try {
          const { data: retData } = await supabase
            .from('returned_inventory')
            .select(`
              id,
              return_tracking_id,
              returned_units,
              return_date,
              item_grade,
              return_reason,
              is_confirmed_defect,
              vendor_eligible_units,
              intake_status,
              notes,
              created_at,
              products (
                sku,
                name,
                category,
                cost_price_inr,
                mrp_inr
              ),
              supplier_batches (
                batch_code,
                vendor_return_deadline
              )
            `)
            .order('created_at', { ascending: false });

          if (Array.isArray(retData)) legacyReturns = retData;

          const { data: alertData } = await supabase
            .from('supplier_quality_alerts')
            .select('*')
            .eq('status', 'open')
            .order('created_at', { ascending: false });

          if (Array.isArray(alertData)) dbAlerts = alertData;
        } catch (err) {
          // Continue with empty array
        }
      }

      res.setHeader('X-Data-Source', 'legacy_returned_inventory');
      res.setHeader('X-Database-Backed', String(Boolean(supabase)));

      return res.status(200).json({
        returns: legacyReturns,
        open_alerts: dbAlerts,
        data_source: 'legacy_returned_inventory',
        is_database_backed: Boolean(supabase),
        database_status: isSupabaseConfigured() ? 'connected' : 'unconfigured',
        total_returns: legacyReturns.length,
        record_count: legacyReturns.length
      });
    }

    // Default / Challenge 10 View: Query live gb_returns (or labeled offline fallback)
    const liveResult = await fetchLiveReturns(supabase);
    const datasetAlerts = getSupplierQualityAnalytics();

    let finalReturns = liveResult.returns;
    let finalAlerts = datasetAlerts;

    if (isCombinedRequested && supabase) {
      try {
        const { data: retData } = await supabase
          .from('returned_inventory')
          .select(`
            id,
            return_tracking_id,
            returned_units,
            return_date,
            item_grade,
            return_reason,
            is_confirmed_defect,
            vendor_eligible_units,
            intake_status,
            notes,
            created_at,
            products (sku, name, category, cost_price_inr, mrp_inr),
            supplier_batches (batch_code, vendor_return_deadline)
          `)
          .order('created_at', { ascending: false });

        if (Array.isArray(retData)) {
          const seen = new Set(finalReturns.map(r => r.return_id || r.id));
          const uniqueLegacy = retData.filter(r => !seen.has(r.id) && !seen.has(r.return_tracking_id));
          finalReturns = [...finalReturns, ...uniqueLegacy];
        }
      } catch (e) {
        // Fallback to purely Gadgetbay returns
      }
    }

    // Deduplication check: guarantee each return appears only once
    const seenIds = new Set();
    const deduplicatedReturns = [];
    for (const ret of finalReturns) {
      const key = ret.return_id || ret.id || ret.return_tracking_id;
      if (!seenIds.has(key)) {
        seenIds.add(key);
        deduplicatedReturns.push(ret);
      }
    }

    res.setHeader('X-Data-Source', liveResult.dataSource);
    res.setHeader('X-Database-Backed', String(liveResult.isDatabaseBacked));

    return res.status(200).json({
      returns: deduplicatedReturns,
      open_alerts: finalAlerts,
      data_source: liveResult.dataSource,
      is_database_backed: liveResult.isDatabaseBacked,
      database_status: liveResult.databaseStatus,
      total_returns: deduplicatedReturns.length,
      notice: liveResult.notice || undefined
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/returns/:id
 * Fetches single return item details.
 */
router.get('/:id', async (req, res, next) => {
  try {
    const id = req.params.id;
    if (id === 'options') {
      return next();
    }

    const supabase = isSupabaseConfigured() ? getSupabaseClient() : null;

    if (supabase) {
      try {
        const { data: dbItem } = await supabase
          .from('gb_returns')
          .select(`
            *,
            gb_products (*)
          `)
          .eq('return_id', id)
          .single();

        if (dbItem) {
          return res.status(200).json({
            ...dbItem,
            data_source: 'supabase_database',
            is_database_backed: true
          });
        }
      } catch (err) {
        // Fall through
      }
    }

    const item = getReturnById(id);
    if (item) {
      return res.status(200).json({
        ...item,
        data_source: 'local_csv_fallback',
        is_database_backed: false,
        notice: 'Loaded from local Challenge 10 dataset fallback (remote gb_* tables not yet migrated).'
      });
    }

    return res.status(404).json({ error: 'Return record not found', id });
  } catch (err) {
    next(err);
  }
});

export default router;
