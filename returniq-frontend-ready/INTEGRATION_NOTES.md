# ReturnIQ Frontend / Backend Add-on Compatibility

This frontend was updated against the API contract in the provided `backend-addon` package.

## Required API behavior

1. `GET /api/returns/options` returns `{ products: [...], batches: [...] }`.
2. `POST /api/returns` accepts `return_tracking_id`, `product_id`, `batch_id`, integer `returned_units`, `item_grade` (`Grade A` through `Grade D`), `return_reason`, boolean `is_confirmed_defect`, integer `vendor_eligible_units`, and optional `return_date` and `notes`.
3. A successful create returns HTTP 201 with `{ return: <inserted database row> }`. The inserted object must include `id` and `return_tracking_id` for the frontend to confirm success.
4. Existing `GET /api/returns`, `GET /api/analytics/pipeline`, `GET /api/health`, and `POST /api/routes/evaluate` remain as in the existing backend.

## Integration order

- First integrate the supplied `backend-addon` into the existing Express backend, following its `INTEGRATE_IN_ANTIGRAVITY.md` file.
- Then run the existing backend on port 5000.
- Set `NEXT_PUBLIC_API_BASE_URL=http://localhost:5000` in this frontend's `.env.local`.
- Run `npm install` and `npm run dev` in the folder containing this frontend's `package.json`.

The form calls the API but does not connect directly to Supabase. A missing intake route is shown as an API error; no fake options or successful saves are used. No database migrations or records are changed by this frontend package.
