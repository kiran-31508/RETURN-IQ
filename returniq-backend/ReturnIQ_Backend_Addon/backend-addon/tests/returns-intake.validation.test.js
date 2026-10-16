import test from "node:test";
import assert from "node:assert/strict";
import { normalizeGrade, validateCreateReturn } from "../src/routes/returns-intake-validation.js";

const validBody = () => ({
  return_tracking_id: "RET-TEST-001",
  product_id: "10000000-0000-0000-0000-000000000001",
  batch_id: "20000000-0000-0000-0000-000000000001",
  returned_units: 10,
  item_grade: "B",
  return_reason: "Packaging damaged",
  is_confirmed_defect: false,
  vendor_eligible_units: 0,
  return_date: "2026-10-10",
});

test("accepts valid payload and normalizes grade", () => {
  const result = validateCreateReturn(validBody());
  assert.deepEqual(result.errors, []);
  assert.equal(result.value.item_grade, "Grade B");
  assert.equal(result.value.intake_status, "received");
});

test("normalizes allowed grade values without accepting other labels", () => {
  assert.equal(normalizeGrade("a"), "Grade A");
  assert.equal(normalizeGrade("Grade D"), "Grade D");
  assert.equal(normalizeGrade("excellent"), null);
});

test("rejects missing required fields", () => {
  const result = validateCreateReturn({});
  assert.ok(result.errors.some(e => e.includes("return_tracking_id")));
  assert.ok(result.errors.some(e => e.includes("product_id")));
  assert.ok(result.errors.some(e => e.includes("batch_id")));
  assert.ok(result.errors.some(e => e.includes("returned_units")));
  assert.ok(result.errors.some(e => e.includes("return_reason")));
});

test("rejects zero, fractional, and non-numeric quantities", () => {
  for (const bad of [0, 1.5, "3"]) {
    const body = validBody(); body.returned_units = bad;
    assert.ok(validateCreateReturn(body).errors.some(e => e.includes("returned_units")));
  }
});

test("rejects invalid grade and vendor-eligible units greater than returned units", () => {
  const body = validBody(); body.item_grade = "Grade X";
  assert.ok(validateCreateReturn(body).errors.some(e => e.includes("item_grade")));
  const body2 = validBody(); body2.vendor_eligible_units = 11;
  assert.ok(validateCreateReturn(body2).errors.some(e => e.includes("cannot exceed")));
});

test("rejects bad dates, non-boolean defect flags, and invalid intake status", () => {
  const body = validBody(); body.return_date = "2026-02-31";
  assert.ok(validateCreateReturn(body).errors.some(e => e.includes("return_date")));
  const body2 = validBody(); body2.is_confirmed_defect = "yes";
  assert.ok(validateCreateReturn(body2).errors.some(e => e.includes("is_confirmed_defect")));
  const body3 = validBody(); body3.intake_status = "pending";
  assert.ok(validateCreateReturn(body3).errors.some(e => e.includes("intake_status")));
});

import { createReturnHandler } from "../src/routes/returns-intake-handlers.js";

function responseHarness() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}
function mockSupabase({ product, batch, inserted = { id: "30000000-0000-0000-0000-000000000001", return_tracking_id: "RET-TEST-001" }, insertError = null }) {
  const calls = { insertPayload: null, insertCount: 0 };
  const supabase = {
    from(table) {
      const query = {
        select() { return this; },
        order() { return this; },
        eq() { return this; },
        maybeSingle() { return Promise.resolve({ data: table === "products" ? product : batch, error: null }); },
        insert(payload) { calls.insertPayload = payload; calls.insertCount += 1; return this; },
        single() { return Promise.resolve({ data: inserted, error: insertError }); },
        then(resolve, reject) {
          const data = table === "products" ? (product ? [product] : []) : (batch ? [batch] : []);
          return Promise.resolve({ data, error: null }).then(resolve, reject);
        },
      };
      return query;
    },
  };
  return { supabase, calls };
}

test("returns 201 only after the database insert succeeds", async () => {
  const product = { id: "10000000-0000-0000-0000-000000000001", supplier_id: "40000000-0000-0000-0000-000000000001" };
  const batch = { id: "20000000-0000-0000-0000-000000000001", product_id: product.id, supplier_id: product.supplier_id };
  const saved = { id: "30000000-0000-0000-0000-000000000001", return_tracking_id: "RET-TEST-001" };
  const { supabase, calls } = mockSupabase({ product, batch, inserted: saved });
  const res = responseHarness();
  await createReturnHandler(supabase)({ body: validBody() }, res);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(res.body, { return: saved });
  assert.equal(calls.insertCount, 1);
  assert.equal(calls.insertPayload.item_grade, "Grade B");
});

test("rejects a batch that does not belong to the selected product without inserting", async () => {
  const product = { id: "10000000-0000-0000-0000-000000000001", supplier_id: "40000000-0000-0000-0000-000000000001" };
  const batch = { id: "20000000-0000-0000-0000-000000000001", product_id: "90000000-0000-0000-0000-000000000009", supplier_id: product.supplier_id };
  const { supabase, calls } = mockSupabase({ product, batch });
  const res = responseHarness();
  await createReturnHandler(supabase)({ body: validBody() }, res);
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /does not belong/);
  assert.equal(calls.insertCount, 0);
});

test("returns 409 for duplicate tracking ID and does not report success", async () => {
  const product = { id: "10000000-0000-0000-0000-000000000001", supplier_id: "40000000-0000-0000-0000-000000000001" };
  const batch = { id: "20000000-0000-0000-0000-000000000001", product_id: product.id, supplier_id: product.supplier_id };
  const { supabase } = mockSupabase({ product, batch, insertError: { code: "23505" } });
  const res = responseHarness();
  await createReturnHandler(supabase)({ body: validBody() }, res);
  assert.equal(res.statusCode, 409);
  assert.match(res.body.error, /already exists/);
});
