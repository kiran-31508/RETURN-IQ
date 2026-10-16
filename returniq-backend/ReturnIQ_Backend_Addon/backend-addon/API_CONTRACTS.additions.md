# Return Intake API Contract Additions

These are intended additions to the existing ReturnIQ `API_CONTRACTS.md`. Merge them into the real backend documentation once the route is integrated.

## `GET /api/returns/options`

Returns product and supplier-batch references for the intake form. The route uses existing database records; it does not create or mutate data.

Success (`200`):

```json
{
  "products": [
    { "id": "<uuid>", "name": "AeroTune Wireless Headphones", "sku": "WH-AERO-01", "supplier_id": "<uuid>", "supplier_name": "SonicWave Electronics Ltd" }
  ],
  "batches": [
    { "id": "<uuid>", "batch_code": "HB-09", "product_id": "<uuid>", "supplier_id": "<uuid>", "supplier_name": "SonicWave Electronics Ltd", "vendor_return_deadline": "2026-10-30" }
  ]
}
```

## `POST /api/returns`

Creates one `returned_inventory` record through the server-side Supabase client. Existing database triggers remain responsible for supplier-quality alert logic.

Request JSON:

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
  "intake_status": "received",
  "notes": "Optional intake notes"
}
```

Required: `return_tracking_id`, `product_id`, `batch_id`, positive integer `returned_units`, valid `item_grade`, and non-empty `return_reason`. `item_grade` accepts `A`, `B`, `C`, `D`, or the exact labels `Grade A` through `Grade D` and stores normalized labels. Defaults: `return_date` uses the database default when omitted; `is_confirmed_defect` defaults to `false`; `vendor_eligible_units` defaults to `0`; `intake_status` defaults to `received`.

The service verifies that the product and batch exist and that the batch references the chosen product before inserting.

Success (`201`):

```json
{ "return": { "id": "<database-generated-uuid>", "return_tracking_id": "RET-NEW-001" } }
```

The `return` body contains the actual row returned by Supabase; the response example above is abbreviated.

Errors:

- `400` invalid JSON data, failed validation, mismatched product/batch, or database constraint violation.
- `404` referenced product or batch not found.
- `409` duplicate unique value, including the return tracking ID.
- `500` unexpected server/database failure, with no credential or raw SQL details exposed.

Never show UI success until the HTTP `201` response arrives. These endpoints do not create recovery plans and do not apply migrations or seed data.
