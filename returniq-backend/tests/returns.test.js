import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

// Ensure test environment before any application code is imported
process.env.NODE_ENV = 'test';
process.env.SUPABASE_URL = 'https://mock-test-project.supabase.co';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'mock-test-service-role-key-ey1234567890';

const MOCK_SUPPLIER_ID = 'a0000000-0000-0000-0000-000000000001';
const MOCK_PRODUCT_ID = 'b0000000-0000-0000-0000-000000000001';
const MOCK_OTHER_PRODUCT_ID = 'b0000000-0000-0000-0000-000000000002';
const MOCK_BATCH_ID = 'c0000000-0000-0000-0000-000000000001';
const MOCK_MISMATCHED_BATCH_ID = 'c0000000-0000-0000-0000-000000000002';

function createMockSupabaseClient() {
  return {
    from(tableName) {
      if (tableName === 'products') {
        return {
          select(columns) {
            return {
              order() {
                return Promise.resolve({
                  data: [
                    {
                      id: MOCK_PRODUCT_ID,
                      sku: 'WH-AERO-01',
                      name: 'AeroTune Wireless Headphones',
                      category: 'Audio',
                      cost_price_inr: 1400.00,
                      mrp_inr: 2500.00,
                      supplier_id: MOCK_SUPPLIER_ID,
                    },
                  ],
                  error: null,
                });
              },
              eq(col, val) {
                return {
                  maybeSingle() {
                    if (val === MOCK_PRODUCT_ID) {
                      return Promise.resolve({
                        data: {
                          id: MOCK_PRODUCT_ID,
                          name: 'AeroTune Wireless Headphones',
                          sku: 'WH-AERO-01',
                          supplier_id: MOCK_SUPPLIER_ID,
                        },
                        error: null,
                      });
                    }
                    return Promise.resolve({ data: null, error: null });
                  },
                };
              },
            };
          },
        };
      }

      if (tableName === 'supplier_batches') {
        return {
          select(columns) {
            return {
              order() {
                return Promise.resolve({
                  data: [
                    {
                      id: MOCK_BATCH_ID,
                      batch_code: 'HB-09',
                      product_id: MOCK_PRODUCT_ID,
                      supplier_id: MOCK_SUPPLIER_ID,
                      received_date: '2026-09-29',
                      vendor_return_deadline: '2026-10-29',
                      units_received: 200,
                      products: {
                        id: MOCK_PRODUCT_ID,
                        sku: 'WH-AERO-01',
                        name: 'AeroTune Wireless Headphones',
                      },
                      suppliers: {
                        id: MOCK_SUPPLIER_ID,
                        name: 'SonicWave Electronics Ltd',
                        code: 'SUP-SW-01',
                      },
                    },
                  ],
                  error: null,
                });
              },
              eq(col, val) {
                return {
                  maybeSingle() {
                    if (val === MOCK_BATCH_ID) {
                      return Promise.resolve({
                        data: {
                          id: MOCK_BATCH_ID,
                          batch_code: 'HB-09',
                          product_id: MOCK_PRODUCT_ID,
                          supplier_id: MOCK_SUPPLIER_ID,
                        },
                        error: null,
                      });
                    }
                    if (val === MOCK_MISMATCHED_BATCH_ID) {
                      return Promise.resolve({
                        data: {
                          id: MOCK_MISMATCHED_BATCH_ID,
                          batch_code: 'OTHER-99',
                          product_id: MOCK_OTHER_PRODUCT_ID,
                          supplier_id: MOCK_SUPPLIER_ID,
                        },
                        error: null,
                      });
                    }
                    return Promise.resolve({ data: null, error: null });
                  },
                };
              },
            };
          },
        };
      }

      if (tableName === 'suppliers') {
        return {
          select(columns) {
            return {
              in(col, val) {
                return Promise.resolve({
                  data: [
                    {
                      id: MOCK_SUPPLIER_ID,
                      name: 'SonicWave Electronics Ltd',
                      code: 'SUP-SW-01',
                    },
                  ],
                  error: null,
                });
              },
            };
          },
        };
      }

      if (tableName === 'returned_inventory') {
        return {
          insert(payload) {
            return {
              select(columns) {
                return {
                  single() {
                    if (payload.return_tracking_id === 'RET-DUPLICATE') {
                      return Promise.resolve({
                        data: null,
                        error: {
                          code: '23505',
                          message: 'duplicate key value violates unique constraint "returned_inventory_return_tracking_id_key"',
                        },
                      });
                    }

                    const inserted = {
                      id: 'd0000000-0000-0000-0000-000000000001',
                      ...payload,
                      return_date: payload.return_date || '2026-10-10',
                      created_at: new Date().toISOString(),
                      updated_at: new Date().toISOString(),
                      products: {
                        id: payload.product_id,
                        sku: 'WH-AERO-01',
                        name: 'AeroTune Wireless Headphones',
                        category: 'Audio',
                        cost_price_inr: 1400.00,
                        mrp_inr: 2500.00,
                      },
                      supplier_batches: {
                        id: payload.batch_id,
                        batch_code: 'HB-09',
                        vendor_return_deadline: '2026-10-29',
                      },
                    };

                    return Promise.resolve({ data: inserted, error: null });
                  },
                };
              },
            };
          },
        };
      }

      throw new Error(`Unexpected table queried in test: ${tableName}`);
    },
  };
}

describe('ReturnIQ Intake API Tests', () => {
  let app;
  let server;
  let baseUrl;

  before(async () => {
    // Dynamic imports guarantee that process.env.NODE_ENV is already set
    const { setSupabaseClient } = await import('../src/supabase.js');
    setSupabaseClient(createMockSupabaseClient());

    const serverModule = await import('../src/server.js');
    app = serverModule.default;

    await new Promise((resolve) => {
      server = app.listen(0, () => {
        const port = server.address().port;
        baseUrl = `http://localhost:${port}`;
        resolve();
      });
    });
  });

  after(async () => {
    if (server) {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  // 1. GET /api/returns/options
  it('GET /api/returns/options returns products and formatted batches', async () => {
    const res = await fetch(`${baseUrl}/api/returns/options`);
    assert.strictEqual(res.status, 200);

    const body = await res.json();
    assert.ok(Array.isArray(body.products), 'products must be an array');
    assert.ok(Array.isArray(body.batches), 'batches must be an array');
    assert.strictEqual(body.products.length, 1);
    assert.strictEqual(body.batches.length, 1);

    const prod = body.products[0];
    assert.strictEqual(prod.id, MOCK_PRODUCT_ID);
    assert.strictEqual(prod.name, 'AeroTune Wireless Headphones');
    assert.strictEqual(prod.sku, 'WH-AERO-01');

    const batch = body.batches[0];
    assert.strictEqual(batch.id, MOCK_BATCH_ID);
    assert.strictEqual(batch.batch_code, 'HB-09');
    assert.strictEqual(batch.product_id, MOCK_PRODUCT_ID);
    assert.strictEqual(batch.product_name, 'AeroTune Wireless Headphones');
    assert.strictEqual(batch.supplier_name, 'SonicWave Electronics Ltd');
  });

  // 2. Missing required fields
  it('POST /api/returns rejects missing return_tracking_id', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        item_grade: 'Grade B',
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('return_tracking_id'));
  });

  it('POST /api/returns rejects missing or invalid product_id UUID', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-001',
        product_id: 'not-a-uuid',
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        item_grade: 'Grade B',
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('product_id'));
  });

  it('POST /api/returns rejects missing or invalid batch_id UUID', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-001',
        product_id: MOCK_PRODUCT_ID,
        batch_id: '',
        returned_units: 10,
        item_grade: 'Grade B',
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('batch_id'));
  });

  it('POST /api/returns rejects missing item_grade', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-001',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('item_grade'));
  });

  it('POST /api/returns rejects missing return_reason', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-001',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        item_grade: 'B',
        return_reason: '   ',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('return_reason'));
  });

  // 3. Invalid units
  it('POST /api/returns rejects zero or negative returned_units', async () => {
    for (const invalidUnits of [0, -5, 3.5, 'ten']) {
      const res = await fetch(`${baseUrl}/api/returns`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          return_tracking_id: 'RET-001',
          product_id: MOCK_PRODUCT_ID,
          batch_id: MOCK_BATCH_ID,
          returned_units: invalidUnits,
          item_grade: 'B',
          return_reason: 'Audio distortion',
        }),
      });
      assert.strictEqual(res.status, 400);
      const body = await res.json();
      const errorText = body.details || body.error || '';
      assert.ok(errorText.includes('returned_units'));
    }
  });

  it('POST /api/returns rejects vendor_eligible_units exceeding returned_units', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-001',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        vendor_eligible_units: 15,
        item_grade: 'B',
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.details || body.error || '';
    assert.ok(errorText.includes('vendor_eligible_units') || errorText.includes('cannot exceed'));
  });

  // 4. Invalid condition grades
  it('POST /api/returns rejects invalid condition grade', async () => {
    for (const invalidGrade of ['E', 'Z', 'Grade F', 'Broken']) {
      const res = await fetch(`${baseUrl}/api/returns`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          return_tracking_id: 'RET-001',
          product_id: MOCK_PRODUCT_ID,
          batch_id: MOCK_BATCH_ID,
          returned_units: 10,
          item_grade: invalidGrade,
          return_reason: 'Audio distortion',
        }),
      });
      assert.strictEqual(res.status, 400);
      const body = await res.json();
      const errorText = body.details || body.error || '';
      assert.ok(errorText.includes('item_grade'));
    }
  });

  // 5. Grade normalization
  it('POST /api/returns normalizes "B" to "Grade B"', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-NORM-01',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        item_grade: 'B',
        return_reason: 'Audio distortion',
      }),
    });
    assert.strictEqual(res.status, 201);
    const body = await res.json();
    assert.strictEqual(body.return.item_grade, 'Grade B');
  });

  // 6. Non-existent product / batch (HTTP 404 per API Contract)
  it('POST /api/returns rejects non-existent product_id', async () => {
    const nonExistentProductId = 'b9999999-9999-9999-9999-999999999999';
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-002',
        product_id: nonExistentProductId,
        batch_id: MOCK_BATCH_ID,
        returned_units: 5,
        item_grade: 'A',
        return_reason: 'Defective cable',
      }),
    });
    assert.strictEqual(res.status, 404);
    const body = await res.json();
    const errorText = body.error || body.details || '';
    assert.ok(errorText.includes('product') && (errorText.includes('not found') || errorText.includes('does not exist')));
  });

  it('POST /api/returns rejects non-existent batch_id', async () => {
    const nonExistentBatchId = 'c9999999-9999-9999-9999-999999999999';
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-003',
        product_id: MOCK_PRODUCT_ID,
        batch_id: nonExistentBatchId,
        returned_units: 5,
        item_grade: 'A',
        return_reason: 'Defective cable',
      }),
    });
    assert.strictEqual(res.status, 404);
    const body = await res.json();
    const errorText = body.error || body.details || '';
    assert.ok(errorText.includes('batch') && (errorText.includes('not found') || errorText.includes('does not exist')));
  });

  // 7. Mismatched product and batch
  it('POST /api/returns rejects mismatched product_id and batch_id', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-004',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_MISMATCHED_BATCH_ID, // belongs to MOCK_OTHER_PRODUCT_ID
        returned_units: 5,
        item_grade: 'Grade A',
        return_reason: 'Cosmetic scratch',
      }),
    });
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    const errorText = body.error || body.details || '';
    assert.ok(errorText.includes('does not belong'));
  });

  // 8. Duplicate tracking ID
  it('POST /api/returns returns 409 Conflict on duplicate return_tracking_id', async () => {
    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        return_tracking_id: 'RET-DUPLICATE',
        product_id: MOCK_PRODUCT_ID,
        batch_id: MOCK_BATCH_ID,
        returned_units: 10,
        item_grade: 'Grade B',
        return_reason: 'Driver crackling',
      }),
    });
    assert.strictEqual(res.status, 409);
    const body = await res.json();
    const errorText = body.error || body.details || '';
    assert.ok(errorText.includes('already exists') || errorText === 'Conflict');
  });

  // 9. Successful creation
  it('POST /api/returns successfully creates intake record and returns HTTP 201', async () => {
    const payload = {
      return_tracking_id: 'RET-NEW-001',
      product_id: MOCK_PRODUCT_ID,
      batch_id: MOCK_BATCH_ID,
      returned_units: 10,
      item_grade: 'B',
      return_reason: 'Audio issue',
      is_confirmed_defect: true,
      vendor_eligible_units: 6,
      notes: 'Dock testing confirmed defect',
    };

    const res = await fetch(`${baseUrl}/api/returns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    assert.strictEqual(res.status, 201);
    const body = await res.json();

    assert.ok(body.return, 'body.return must exist');
    assert.strictEqual(body.return.return_tracking_id, 'RET-NEW-001');
    assert.strictEqual(body.return.product_id, MOCK_PRODUCT_ID);
    assert.strictEqual(body.return.batch_id, MOCK_BATCH_ID);
    assert.strictEqual(body.return.returned_units, 10);
    assert.strictEqual(body.return.item_grade, 'Grade B');
    assert.strictEqual(body.return.return_reason, 'Audio issue');
    assert.strictEqual(body.return.is_confirmed_defect, true);
    assert.strictEqual(body.return.vendor_eligible_units, 6);
    assert.strictEqual(body.return.intake_status, 'received');
    assert.strictEqual(body.return.notes, 'Dock testing confirmed defect');
    assert.ok(body.return.products, 'joined product info returned');
    assert.ok(body.return.supplier_batches, 'joined batch info returned');
  });
});
