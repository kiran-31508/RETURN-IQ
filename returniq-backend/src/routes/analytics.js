import { Router } from 'express';
import { getSupabaseClient, isSupabaseConfigured } from '../supabase.js';
import { getPipelineAnalytics, getSupplierQualityAnalytics } from '../services/recoveryEngine.js';

const router = Router();

/**
 * GET /api/analytics/pipeline
 * Queries recovery pipeline summary and vendor compliance.
 * Clearly differentiates live Supabase analytical views from dataset calculations.
 */
router.get('/pipeline', async (req, res, next) => {
  try {
    const engineAnalytics = getPipelineAnalytics();
    let dbPipeline = null;
    let dbVendor = [];
    let isDbBacked = false;

    if (isSupabaseConfigured()) {
      try {
        const supabase = getSupabaseClient();
        if (supabase) {
          const { data: pData } = await supabase
            .from('vw_recovery_pipeline_summary')
            .select('*')
            .single();
          if (pData) {
            dbPipeline = pData;
            isDbBacked = true;
          }

          const { data: vData } = await supabase
            .from('vw_vendor_compliance_and_rtv')
            .select('*');
          if (Array.isArray(vData)) dbVendor = vData;
        }
      } catch (err) {
        // Use engine analytics fallback
      }
    }

    const mergedPipeline = {
      ...engineAnalytics.pipeline_summary,
      ...(dbPipeline && dbPipeline.total_plans > 0 ? dbPipeline : {
        total_plans: dbPipeline ? dbPipeline.total_plans : 0,
        approved_plans_count: dbPipeline ? dbPipeline.approved_plans_count : 0,
        pending_approval_count: dbPipeline ? dbPipeline.pending_approval_count : 0
      })
    };

    return res.status(200).json({
      pipeline_summary: mergedPipeline,
      metrics: engineAnalytics.metrics,
      vendor_compliance: dbVendor,
      data_source: isDbBacked ? 'supabase_database' : 'local_csv_fallback',
      is_database_backed: isDbBacked,
      database_status: isSupabaseConfigured() ? (isDbBacked ? 'connected' : 'pending_migration') : 'unconfigured'
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/analytics/supplier-quality
 * Real defect analytics derived from return reasons across all suppliers.
 */
router.get('/supplier-quality', async (req, res, next) => {
  try {
    const alerts = getSupplierQualityAnalytics();
    return res.status(200).json({
      alerts,
      data_source: 'dataset_analytics',
      total_alerts: alerts.length
    });
  } catch (err) {
    next(err);
  }
});

export default router;
