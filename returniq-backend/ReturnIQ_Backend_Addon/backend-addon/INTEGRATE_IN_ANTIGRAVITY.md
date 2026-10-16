# Safely integrate the ReturnIQ intake router

The route module is additive. Do not replace `src/routes/returns.js`; it already owns the existing GET inventory route.

1. Copy `src/routes/returns-intake.js` and `src/routes/returns-intake-validation.js` into the actual backend's `src/routes/` directory.
2. Open the real `src/supabase.js` and inspect how it exports the existing Supabase client. Reuse that exact client; do not create a second client and do not print credentials.
3. In `src/server.js`, import `createReturnsIntakeRouter` from `./routes/returns-intake.js`.
4. Mount the new router at `/api/returns` **after** the existing `app.use('/api/returns', returnsRoutes)` registration but **before** the final 404/error handler. Pass the existing Supabase client to `createReturnsIntakeRouter(existingSupabaseClient)`. Adapt the variable/import name to the export actually present in `src/supabase.js`.
5. Add the two endpoint contracts to the existing `API_CONTRACTS.md`.
6. Run validation-only tests in this add-on with `npm test`; then run the backend's test suite. Do not send any POST request to the connected database until the user explicitly approves a staging test.
7. Verify `GET /api/returns`, `/api/health`, `/api/analytics/pipeline`, `/api/routes/evaluate`, and the existing `/api/plans` routes remain unchanged.

## Intended POST contract

`POST /api/returns` JSON:

```json
{
  "return_tracking_id": "RET-NEW-001",
  "product_id": "<existing-product-uuid>",
  "batch_id": "<existing-batch-uuid>",
  "returned_units": 10,
  "item_grade": "Grade B",
  "return_reason": "Audio issue",
  "return_date": "2026-10-10",
  "is_confirmed_defect": false,
  "vendor_eligible_units": 0,
  "notes": "Optional intake notes"
}
```

`item_grade` also accepts `A`, `B`, `C`, or `D`; the route normalizes these to the exact schema labels. `intake_status` is optional and defaults to `received`.

Success: HTTP `201` with `{ "return": <inserted row> }`.

Validation error: HTTP `400`; duplicate tracking ID: HTTP `409`; missing product or batch: HTTP `404`; database/server failure: a safe error response.

`GET /api/returns/options` returns actual records in this shape:

```json
{
  "products": [
    { "id": "<uuid>", "name": "Product name", "sku": "SKU", "supplier_id": "<uuid>", "supplier_name": "Supplier name" }
  ],
  "batches": [
    { "id": "<uuid>", "batch_code": "BATCH-001", "product_id": "<uuid>", "supplier_id": "<uuid>", "supplier_name": "Supplier name", "vendor_return_deadline": "2026-10-30" }
  ]
}
```

Options may be empty if the database contains no matching rows. No mock options should be inserted.

## Paste-ready integration prompt for the local Antigravity backend

Copy the two JS files from this package into the existing backend's `src/routes/` folder, then paste the following into Antigravity while the **actual `returniq-backend` project is open**:

> Integrate the already copied `src/routes/returns-intake.js` and `src/routes/returns-intake-validation.js` into this existing ReturnIQ Express backend. Inspect `src/server.js`, `src/supabase.js`, `src/routes/returns.js`, `src/routes/evaluate.js`, and `API_CONTRACTS.md` before editing. Reuse the actual existing Supabase client export and add the new router at `/api/returns` after the existing inventory router and before the final 404/error handler, so existing GET `/api/returns` remains unchanged while POST `/api/returns` and GET `/api/returns/options` are added. Update `API_CONTRACTS.md` using `backend-addon/API_CONTRACTS.additions.md`. Also inspect the UUID format check in `src/routes/evaluate.js`: if it uses UUID version/variant bits, change it to validate canonical 8-4-4-4-12 hexadecimal formatting only, because the existing deterministic seeded IDs may not carry standard version/variant bits. Do not apply migrations, reseed, connect to or write to Supabase during implementation, or send a real POST request. Run safe tests only, preserve all existing endpoints, and report exact files changed and remaining unverified behavior. Do not print or expose secrets.

After that integration is complete, run the backend in one terminal and the frontend in another. The actual end-to-end database write must be tested only after you explicitly approve testing a new return in the staging database.
