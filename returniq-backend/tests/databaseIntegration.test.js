import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  fetchLiveReturns,
  evaluateLiveReturn,
  calculateRecoveryRoutes,
  SNAPSHOT_DATE_STR
} from '../src/services/recoveryEngine.js';
import { validateDataset, EXPECTED_SCHEMAS } from '../scripts/import_gadgetbay.js';
import {
  getSupabaseClient,
  isSupabaseConfigured,
  getSupabaseDiagnostic
} from '../src/supabase.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const GADGETBAY_DIR = path.resolve(__dirname, '../data/gadgetbay');

describe('[TEST SUITE 1] Dataset Validation & Integrity Checks', () => {

  test('validates all 7 judge CSV files successfully with zero errors', () => {
    const result = validateDataset(GADGETBAY_DIR);
    assert.equal(result.isValid, true);
    assert.equal(result.errors.length, 0);
  });

  test('detects header schema requirements for all 7 files', () => {
    assert.equal(Object.keys(EXPECTED_SCHEMAS).length, 7);
    assert.deepEqual(EXPECTED_SCHEMAS['inventory.csv'].headers, ['sku', 'new_stock', 'avg_daily_demand']);
    assert.deepEqual(EXPECTED_SCHEMAS['vendor_terms.csv'].headers, ['supplier', 'sku', 'rtv_allowed', 'credit_pct', 'window_days']);
  });

  test('benchmark snapshot date is consistently 2026-11-16', () => {
    assert.equal(SNAPSHOT_DATE_STR, '2026-11-16');
  });

});

describe('[TEST SUITE 2] Database-Backed vs Fallback Behavior', () => {

  test('fetchLiveReturns falls back cleanly and transparently when database tables are unavailable', async () => {
    // When Supabase is null or table does not exist
    const mockSupabaseMissingTable = {
      from: () => ({
        select: () => ({
          order: async () => ({ data: null, error: { message: 'relation gb_returns does not exist' } })
        })
      })
    };

    const result = await fetchLiveReturns(mockSupabaseMissingTable);
    assert.equal(result.isDatabaseBacked, false);
    assert.equal(result.dataSource, 'local_csv_fallback');
    assert.equal(result.recordCount, 918);
    assert.ok(result.notice.includes('not yet migrated'));
  });

  test('fetchLiveReturns returns live database records when gb_* tables are populated', async () => {
    const mockDbRow = {
      return_id: 'R99999',
      date_received: '2026-11-01',
      sku: 'GB-001',
      supplier_batch: 'BATCH-01',
      reason_code: 'Performance issue',
      condition_grade: 'B',
      status: 'Awaiting decision',
      gb_products: {
        product: 'Wireless Earbuds Lite',
        category: 'Audio',
        cost_price: 2847,
        selling_price: 4400,
        supplier: 'TechLink Distributors'
      }
    };

    const mockSupabaseWithTable = {
      from: (tbl) => {
        assert.equal(tbl, 'gb_returns');
        return {
          select: () => ({
            order: async () => ({ data: [mockDbRow], error: null })
          })
        };
      }
    };

    const result = await fetchLiveReturns(mockSupabaseWithTable);
    assert.equal(result.isDatabaseBacked, true);
    assert.equal(result.dataSource, 'supabase_database');
    assert.equal(result.databaseStatus, 'connected');
    assert.equal(result.recordCount, 1);
    assert.equal(result.returns[0].return_id, 'R99999');
    assert.equal(result.returns[0].product_name, 'Wireless Earbuds Lite');
  });

  test('evaluateLiveReturn labels data source as supabase_database when record exists in database', async () => {
    const mockSupabase = {
      from: (tbl) => ({
        select: () => ({
          eq: () => ({
            single: async () => {
              if (tbl === 'gb_returns') {
                return {
                  data: {
                    return_id: 'R-TEST-DB',
                    sku: 'GB-001',
                    condition_grade: 'B',
                    date_received: '2026-11-10',
                    supplier_batch: 'BATCH-99'
                  },
                  error: null
                };
              }
              if (tbl === 'gb_products') {
                return {
                  data: { cost_price: 2847, selling_price: 4400, category: 'Audio' },
                  error: null
                };
              }
              if (tbl === 'gb_inventory') {
                return {
                  data: { new_stock: 32, avg_daily_demand: 1.3 },
                  error: null
                };
              }
              if (tbl === 'gb_vendor_terms') {
                return {
                  data: { rtv_allowed: true, credit_pct: 0.6, window_days: 30 },
                  error: null
                };
              }
              return { data: null, error: null };
            }
          }),
          then: async (resolve) => {
            if (tbl === 'gb_refurbishment') {
              resolve({ data: [{ category: 'Audio', refurb_cost: 250, days_required: 5, resale_pct_of_new: 0.75 }] });
            } else if (tbl === 'gb_liquidation') {
              resolve({ data: [{ category: 'Audio', condition_grade: 'B', recovery_pct_of_cost: 0.35 }] });
            } else {
              resolve({ data: [] });
            }
          }
        })
      })
    };

    const evalResult = await evaluateLiveReturn(mockSupabase, 'R-TEST-DB');
    assert.ok(evalResult);
    assert.equal(evalResult.isDatabaseBacked, true);
    assert.equal(evalResult.dataSource, 'supabase_database');
    assert.equal(evalResult.routes.length, 4);

    const rtv = evalResult.routes.find(r => r.route === 'return_to_vendor');
    assert.equal(rtv.is_eligible, true);
    assert.equal(rtv.data_source, 'supabase_database');
  });

  test('evaluateLiveReturn falls back transparently when table is missing', async () => {
    const mockSupabaseErr = {
      from: () => ({
        select: () => ({
          eq: () => ({
            single: async () => ({ data: null, error: { message: 'Table gb_returns does not exist' } })
          })
        })
      })
    };

    const evalResult = await evaluateLiveReturn(mockSupabaseErr, 'R50813');
    assert.ok(evalResult);
    assert.equal(evalResult.isDatabaseBacked, false);
    assert.equal(evalResult.dataSource, 'local_csv_fallback');
    assert.ok(evalResult.notice.includes('local Challenge 10 dataset fallback'));
  });

  test('calculateRecoveryRoutes distinguishes gross recovery, cost, net margin, and channel types', () => {
    const routes = calculateRecoveryRoutes({
      sku: 'GB-002',
      condition_grade: 'B',
      date_received: '2026-11-05',
      cost_price: 2672,
      selling_price: 5213,
      category: 'Audio',
      new_stock: 44,
      avg_daily_demand: 1.6,
      rtv_allowed: true,
      credit_pct: 0.6,
      window_days: 30,
      refurb_cost: 250,
      days_required: 5,
      resale_pct_of_new: 0.75,
      liq_pct: 0.35,
      returned_units: 1,
      dataSource: 'test_engine'
    });

    assert.equal(routes.length, 4);

    // Restock: Ineligible (Grade B != Grade A)
    const restock = routes.find(r => r.route === 'restock');
    assert.equal(restock.is_eligible, false);

    // RTV: Eligible within 30 days (11 days elapsed)
    const rtv = routes.find(r => r.route === 'return_to_vendor');
    assert.equal(rtv.is_eligible, true);
    assert.equal(rtv.recovery_channel_type, 'supplier_credit');
    assert.equal(rtv.unit_net_recovery_inr, Math.round(2672 * 0.6));

    // Refurb: Eligible (5213 * 0.75 = 3910 gross, - 250 cost = 3660 net)
    const refurb = routes.find(r => r.route === 'refurbish_and_resell');
    assert.equal(refurb.is_eligible, true);
    assert.equal(refurb.unit_gross_recovery_inr, 3910);
    assert.equal(refurb.unit_cost_inr, 250);
    assert.equal(refurb.unit_net_recovery_inr, 3660);
    assert.equal(refurb.recovery_channel_type, 'cash');

    // Liquidation: Eligible (2672 * 0.35 = 935)
    const liq = routes.find(r => r.route === 'liquidation');
    assert.equal(liq.is_eligible, true);
    assert.equal(liq.unit_net_recovery_inr, Math.round(2672 * 0.35));
    assert.equal(liq.recovery_channel_type, 'cash');
  });

});

describe('[TEST SUITE 3] Supabase Client Initialization & Safe Diagnostics', () => {

  test('getSupabaseDiagnostic reports configuration safely without leaking credentials', () => {
    const diag = getSupabaseDiagnostic();
    assert.equal(typeof diag.configured, 'boolean');
    assert.equal(typeof diag.clientInitialized, 'boolean');
    assert.equal('serviceRoleKey' in diag, false);
    assert.equal('SUPABASE_SERVICE_ROLE_KEY' in diag, false);
    if (diag.configured) {
      assert.equal(diag.clientInitialized, true);
      assert.equal(typeof diag.projectHost, 'string');
      assert.equal(diag.serviceRoleKeyConfigured, true);
    }
  });

  test('getSupabaseClient returns valid initialized client with .from() method', () => {
    if (isSupabaseConfigured()) {
      const client = getSupabaseClient();
      assert.notEqual(client, null);
      assert.equal(typeof client.from, 'function');
    }
  });

});

describe('[TEST SUITE 4] Gadgetbay Challenge 10 Returns Isolation & Integrity', () => {

  test('GET /api/returns returns exactly 918 returns matching Gadgetbay judge dataset without legacy records', async () => {
    process.env.NODE_ENV = 'test';
    const serverModule = await import('../src/server.js');
    const app = serverModule.default;

    const server = await new Promise((resolve) => {
      const s = app.listen(0, () => resolve(s));
    });
    const port = server.address().port;

    try {
      const res = await fetch(`http://localhost:${port}/api/returns`);
      assert.equal(res.status, 200);
      const data = await res.json();

      // Assert exactly 918 returns
      assert.equal(data.returns.length, 918);
      assert.equal(data.total_returns, 918);

      // Assert no duplicates (each return appears exactly once)
      const returnIds = data.returns.map(r => r.return_id);
      const uniqueIds = new Set(returnIds);
      assert.equal(uniqueIds.size, 918);

      // Assert legacy records are NOT mixed into the Challenge 10 view
      assert.equal(uniqueIds.has('RET-HB09-2026'), false);
      assert.equal(uniqueIds.has('RET-INTAKE-6265'), false);
      assert.equal(uniqueIds.has('d0000000-0000-0000-0000-000000000001'), false);

      // Assert all records are valid Gadgetbay R-series returns
      for (const ret of data.returns) {
        assert.ok(/^R\d{5}$/.test(ret.return_id), `Expected R-series return_id, found ${ret.return_id}`);
        assert.ok(typeof ret.sku === 'string' && ret.sku.length > 0);
        assert.ok(['A', 'B', 'C', 'D'].includes(ret.condition_grade));
      }
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  test('GET /api/returns?source=legacy keeps legacy returned_inventory isolated', async () => {
    process.env.NODE_ENV = 'test';
    const serverModule = await import('../src/server.js');
    const app = serverModule.default;

    const server = await new Promise((resolve) => {
      const s = app.listen(0, () => resolve(s));
    });
    const port = server.address().port;

    try {
      const res = await fetch(`http://localhost:${port}/api/returns?source=legacy`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.data_source, 'legacy_returned_inventory');
      if (data.is_database_backed) {
        assert.equal(data.returns.length, 2);
      }
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

});

describe('[TEST SUITE 5] Recovery Route Evaluation & UI Distinction (Challenge 10)', () => {

  test('POST /api/routes/evaluate evaluates eligible Grade A return (R50369) with distinct gross/net and payment channels', async () => {
    process.env.NODE_ENV = 'test';
    const serverModule = await import('../src/server.js');
    const app = serverModule.default;

    const server = await new Promise((resolve) => {
      const s = app.listen(0, () => resolve(s));
    });
    const port = server.address().port;

    try {
      const res = await fetch(`http://localhost:${port}/api/routes/evaluate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ return_id: 'R50369' })
      });

      assert.equal(res.status, 200);
      const routes = await res.json();
      assert.ok(Array.isArray(routes));
      assert.equal(routes.length, 4);

      const byRoute = Object.fromEntries(routes.map(r => [r.route, r]));

      // 1. Restock Route (Eligible Grade A)
      const restock = byRoute['restock'];
      assert.ok(restock, 'Restock route must be present');
      assert.equal(restock.is_eligible, true);
      assert.equal(restock.ineligibility_reason, null);
      assert.equal(restock.recovery_channel_type, 'cash');
      assert.equal(restock.eligible_units, 1);
      assert.equal(restock.unit_gross_recovery_inr, 3267);
      assert.equal(restock.unit_cost_inr, 0);
      assert.equal(restock.unit_net_recovery_inr, 3267);
      assert.equal(restock.potential_total_net_inr, 3267);
      assert.equal(restock.estimated_days_to_realize, 1);

      // 2. Return to Vendor Route (Eligible, Supplier Credit)
      const rtv = byRoute['return_to_vendor'];
      assert.ok(rtv, 'RTV route must be present');
      assert.equal(rtv.is_eligible, true);
      assert.equal(rtv.ineligibility_reason, null);
      assert.equal(rtv.recovery_channel_type, 'supplier_credit');
      assert.equal(rtv.eligible_units, 1);
      assert.equal(rtv.unit_gross_recovery_inr, 1391);
      assert.equal(rtv.unit_cost_inr, 0);
      assert.equal(rtv.unit_net_recovery_inr, 1391);
      assert.equal(rtv.potential_total_net_inr, 1391);
      assert.equal(rtv.estimated_days_to_realize, 14);

      // 3. Refurbish and Resell (Eligible with incremental refurb cost)
      const refurb = byRoute['refurbish_and_resell'];
      assert.ok(refurb, 'Refurb route must be present');
      assert.equal(refurb.is_eligible, true);
      assert.equal(refurb.ineligibility_reason, null);
      assert.equal(refurb.recovery_channel_type, 'cash');
      assert.equal(refurb.eligible_units, 1);
      assert.equal(refurb.unit_gross_recovery_inr, 2287);
      assert.equal(refurb.unit_cost_inr, 450);
      assert.equal(refurb.unit_net_recovery_inr, 1837);
      assert.equal(refurb.potential_total_net_inr, 1837);
      assert.equal(refurb.unit_gross_recovery_inr - refurb.unit_cost_inr, refurb.unit_net_recovery_inr);
      assert.equal(refurb.estimated_days_to_realize, 7);

      // 4. Liquidation (Eligible cash floor)
      const liq = byRoute['liquidation'];
      assert.ok(liq, 'Liquidation route must be present');
      assert.equal(liq.is_eligible, true);
      assert.equal(liq.recovery_channel_type, 'cash');
      assert.equal(liq.eligible_units, 1);
      assert.equal(liq.unit_gross_recovery_inr, 1093);
      assert.equal(liq.unit_cost_inr, 0);
      assert.equal(liq.unit_net_recovery_inr, 1093);
      assert.equal(liq.potential_total_net_inr, 1093);
      assert.equal(liq.estimated_days_to_realize, 3);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  test('POST /api/routes/evaluate evaluates ineligible condition (R50177 Grade D) with clear rejection reasons', async () => {
    process.env.NODE_ENV = 'test';
    const serverModule = await import('../src/server.js');
    const app = serverModule.default;

    const server = await new Promise((resolve) => {
      const s = app.listen(0, () => resolve(s));
    });
    const port = server.address().port;

    try {
      const res = await fetch(`http://localhost:${port}/api/routes/evaluate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ return_id: 'R50177' })
      });

      assert.equal(res.status, 200);
      const routes = await res.json();
      assert.ok(Array.isArray(routes));
      assert.equal(routes.length, 4);

      const byRoute = Object.fromEntries(routes.map(r => [r.route, r]));

      // 1. Restock Ineligible (Grade D non-Grade A)
      const restock = byRoute['restock'];
      assert.ok(restock);
      assert.equal(restock.is_eligible, false);
      assert.ok(restock.ineligibility_reason.includes('Grade A'));
      assert.equal(restock.eligible_units, 0);
      assert.equal(restock.potential_total_net_inr, 0);

      // 2. RTV Ineligible (Expired vendor window)
      const rtv = byRoute['return_to_vendor'];
      assert.ok(rtv);
      assert.equal(rtv.is_eligible, false);
      assert.ok(rtv.ineligibility_reason.includes('expired'));
      assert.equal(rtv.recovery_channel_type, 'supplier_credit');
      assert.equal(rtv.eligible_units, 0);
      assert.equal(rtv.potential_total_net_inr, 0);

      // 3. Refurb Ineligible (Grade D scrap condition)
      const refurb = byRoute['refurbish_and_resell'];
      assert.ok(refurb);
      assert.equal(refurb.is_eligible, false);
      assert.ok(refurb.ineligibility_reason.includes('Grade D'));
      assert.equal(refurb.eligible_units, 0);
      assert.equal(refurb.potential_total_net_inr, 0);

      // 4. Liquidation Remains Eligible (Floor option)
      const liq = byRoute['liquidation'];
      assert.ok(liq);
      assert.equal(liq.is_eligible, true);
      assert.equal(liq.recovery_channel_type, 'cash');
      assert.equal(liq.eligible_units, 1);
      assert.equal(liq.unit_gross_recovery_inr, 199);
      assert.equal(liq.unit_cost_inr, 0);
      assert.equal(liq.unit_net_recovery_inr, 199);
      assert.equal(liq.potential_total_net_inr, 199);
      assert.equal(liq.estimated_days_to_realize, 3);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

});



