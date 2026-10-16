# ReturnIQ Frontend

Updated dark-themed Next.js dashboard designed to work with the existing ReturnIQ Express backend and the `backend-addon` return-intake routes. The visual template remains dark navy with blue accents. The browser calls Express only; it never connects directly to Supabase and must not contain a service-role key.

## Run on Windows

1. Open a terminal in this folder (the one containing `package.json`).
2. Install dependencies: `npm install`.
3. Copy `.env.example` to `.env.local`.
4. Confirm `.env.local` contains `NEXT_PUBLIC_API_BASE_URL=http://localhost:5000`.
5. Start your existing Express backend in a separate terminal on port `5000`.
6. Run `npm run dev` and open `http://localhost:3000`.

## Backend endpoints used

- `GET /api/health` — backend health/connection indicator.
- `GET /api/returns` — real return inventory and any alert records included in the response.
- `GET /api/analytics/pipeline` — real pipeline metrics, when provided.
- `GET /api/returns/options` — real products and supplier batches for the intake form. Requires the intake add-on to be integrated into the existing Express backend.
- `POST /api/returns` — validates and creates a return using the exact intake contract. Requires the intake add-on to be integrated; the frontend only displays success after a 201 response containing `{ "return": <inserted row> }`.
- `POST /api/routes/evaluate` with `{ "return_id": "<uuid>" }` — evaluates recovery routes for the selected existing return.

## Features

- Existing overview/dashboard template, live backend status, returns inventory, recovery planning, and supplier-quality sections.
- New Return modal with real product/batch options, product-filtered batch dropdown, positive whole-number quantity validation, valid grades, explicit vendor-eligible units, optional date/notes, and confirmed-defect flag.
- The client checks product/batch consistency, while the backend must validate it again before any insert.
- Save confirmation is shown only after the backend returns a successful saved row; API errors preserve the form content.
- Inventory search by tracking ID, product, SKU, supplier, and batch; grade/status filters; pagination; row details; CSV export.
- Supplier alert search and severity filters.
- Recovery route cards use returned API values only. Missing analytics values are shown as `—`; no mock records or financial values are substituted.

## Required backend integration

Before using Add Return, integrate `backend-addon` into the original Express backend using `backend-addon/INTEGRATE_IN_ANTIGRAVITY.md`. The new endpoints are not created just by running the frontend. Do not apply migrations or send a real POST request until the backend is reviewed and a staging test is approved.

Do not place Supabase URLs with service-role credentials, `SUPABASE_SERVICE_ROLE_KEY`, or any secret in `.env.local`. The only frontend environment value should be the Express API base URL.
