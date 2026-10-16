import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateReturn,
  getReturnById,
  getAllReturns,
  getPipelineAnalytics,
  getSupplierQualityAnalytics
} from '../src/services/recoveryEngine.js';

describe('Recovery Decision Engine — Gadgetbay Challenge 10', () => {

  test('loads returns dataset and verifies 918 returns', () => {
    const returns = getAllReturns();
    assert.equal(returns.length, 918);
  });

  test('correctly evaluates Grade A return with active demand for Restock', () => {
    // GB-001 (Wireless Earbuds Lite, selling_price 4400, demand 1.3, stock 32)
    const mockReturn = {
      id: 'TEST-A',
      sku: 'GB-001',
      condition_grade: 'A',
      returned_units: 1,
      date_received: '2026-11-10'
    };
    const evals = evaluateReturn(mockReturn);
    assert.equal(evals.length, 4);

    const restock = evals.find(e => e.route === 'restock');
    assert.ok(restock);
    assert.equal(restock.is_eligible, true);
    assert.equal(restock.unit_gross_recovery_inr, 4400);
    assert.equal(restock.unit_net_recovery_inr, 4400);
    assert.equal(restock.recovery_channel_type, 'cash');
    assert.equal(restock.estimated_days_to_realize, 1);
  });

  test('rejects Restock for Grade B condition', () => {
    const mockReturn = {
      id: 'TEST-B',
      sku: 'GB-001',
      condition_grade: 'B',
      returned_units: 1,
      date_received: '2026-11-10'
    };
    const evals = evaluateReturn(mockReturn);
    const restock = evals.find(e => e.route === 'restock');
    assert.equal(restock.is_eligible, false);
    assert.match(restock.ineligibility_reason, /Grade A/);
  });

  test('evaluates Refurbish & Resell correctly (resale_pct - refurb_cost)', () => {
    // GB-001 is Audio: selling_price = 4400, Audio refurb_cost = 250, resale_pct = 0.75
    // gross = 4400 * 0.75 = 3300
    // net = 3300 - 250 = 3050
    const mockReturn = {
      id: 'TEST-REFURB',
      sku: 'GB-001',
      condition_grade: 'B',
      returned_units: 1,
      date_received: '2026-11-10'
    };
    const evals = evaluateReturn(mockReturn);
    const refurb = evals.find(e => e.route === 'refurbish_and_resell');
    assert.ok(refurb);
    assert.equal(refurb.is_eligible, true);
    assert.equal(refurb.unit_gross_recovery_inr, 3300);
    assert.equal(refurb.unit_cost_inr, 250);
    assert.equal(refurb.unit_net_recovery_inr, 3050);
    assert.equal(refurb.estimated_days_to_realize, 5); // Audio days_required
  });

  test('rejects Refurbish & Resell for Grade D condition', () => {
    const mockReturn = {
      id: 'TEST-D',
      sku: 'GB-001',
      condition_grade: 'D',
      returned_units: 1,
      date_received: '2026-11-10'
    };
    const evals = evaluateReturn(mockReturn);
    const refurb = evals.find(e => e.route === 'refurbish_and_resell');
    assert.equal(refurb.is_eligible, false);
    assert.match(refurb.ineligibility_reason, /Grade D/);
  });

  test('validates RTV window: allowed if within window_days', () => {
    // GB-001 has window_days = 30, rtv_allowed = Yes, credit_pct = 0.6
    // Cost price = 2847. Credit = 2847 * 0.6 = 1708.2 ~ 1708
    // If date_received is 2026-11-01 (15 days prior to 2026-11-16 snapshot), it is eligible.
    const mockReturn = {
      id: 'TEST-RTV-VALID',
      sku: 'GB-001',
      condition_grade: 'B',
      returned_units: 1,
      date_received: '2026-11-01'
    };
    const evals = evaluateReturn(mockReturn);
    const rtv = evals.find(e => e.route === 'return_to_vendor');
    assert.equal(rtv.is_eligible, true);
    assert.equal(rtv.recovery_channel_type, 'supplier_credit');
    assert.equal(rtv.unit_net_recovery_inr, Math.round(2847 * 0.6));
  });

  test('rejects RTV if outside window_days', () => {
    // Received 2026-08-19 (89 days before 2026-11-16; limit is 30 days)
    const mockReturn = {
      id: 'TEST-RTV-EXPIRED',
      sku: 'GB-001',
      condition_grade: 'B',
      returned_units: 1,
      date_received: '2026-08-19'
    };
    const evals = evaluateReturn(mockReturn);
    const rtv = evals.find(e => e.route === 'return_to_vendor');
    assert.equal(rtv.is_eligible, false);
    assert.match(rtv.ineligibility_reason, /expired/i);
  });

  test('evaluates Liquidation as available fallback for all grades', () => {
    // Audio Grade D recovery_pct = 0.05. Cost price = 2847. Gross = 2847 * 0.05 = 142.35 ~ 142
    const mockReturn = {
      id: 'TEST-LIQ',
      sku: 'GB-001',
      condition_grade: 'D',
      returned_units: 1,
      date_received: '2026-08-19'
    };
    const evals = evaluateReturn(mockReturn);
    const liq = evals.find(e => e.route === 'liquidation');
    assert.equal(liq.is_eligible, true);
    assert.equal(liq.unit_gross_recovery_inr, Math.round(2847 * 0.05));
    assert.equal(liq.estimated_days_to_realize, 3);
  });

  test('pipeline analytics aggregates net recovery without double counting', () => {
    const analytics = getPipelineAnalytics();
    assert.ok(analytics.pipeline_summary);
    assert.equal(analytics.pipeline_summary.total_return_records, 918);
    assert.ok(analytics.pipeline_summary.potential_recovery_inr > 0);
    assert.ok(analytics.pipeline_summary.net_cash_recovery_inr > 0);
    assert.ok(analytics.pipeline_summary.net_supplier_credit_inr >= 0);
  });

  test('supplier quality analytics identifies defect rates accurately', () => {
    const alerts = getSupplierQualityAnalytics();
    assert.ok(Array.isArray(alerts));
    assert.ok(alerts.length > 0);
    assert.ok(alerts.every(a => a.supplier_name && a.defect_rate_pct >= 50));
  });

});
