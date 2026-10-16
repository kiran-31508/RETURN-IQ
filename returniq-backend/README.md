# ReturnIQ Backend API

Reverse logistics and supplier quality intelligence backend service for CYPHER 2026 Hackathon.

ReturnIQ identifies optimal value recovery pathways for returned merchandise (Restock, Return to Vendor, Refurbish & Resell, Liquidation), isolates cash returns from supplier credits in INR (₹), and automatically flags anomalous supplier defect rates.

---

## Architecture & Security Model

```
┌──────────────────────────────────────┐
│ Frontend Application (Vite / Next)   │
│ Port 3000 / 5173                     │
└──────────────────┬───────────────────┘
                   │ Standard JSON HTTP requests
                   ▼
┌────────────────────────────────────────────────────────┐
│ ReturnIQ Express Server (Port 5000)                    │
│ • Securely holds SUPABASE_SERVICE_ROLE_KEY             │
│ • CORS strictly restricted to ALLOWED_ORIGINS          │
│ • Validates inputs, strips client calculations        │
│ • Enforces server-side approval timestamps             │
└──────────────────┬─────────────────────────────────────┘
                   │ Private PostgreSQL connection (bypasses RLS)
                   ▼
┌────────────────────────────────────────────────────────┐
│ Supabase PostgreSQL Database                           │
│ • RLS enabled on all 7 tables (Deny all anon keys)     │
│ • Migration: 20261009000002_returniq_reverse_logistics │
│ • Generated STORED columns for economic totals         │
│ • Row-locking triggers on allocation quotas            │
└────────────────────────────────────────────────────────┘
```

---

## Local Setup Instructions

### 1. Prerequisites
- Node.js version 18.0.0 or higher.
- A Supabase project with migration `20261009000002_returniq_reverse_logistics_v2.sql` applied.

### 2. Install Dependencies
Run from the `returniq-backend` directory:
```bash
npm install
```

### 3. Configure Environment Variables
Copy the `.env.example` template to `.env`:
```bash
cp .env.example .env
```
Edit `.env` with your Supabase credentials (from your Supabase Dashboard -> **Project Settings** -> **API**):
```env
PORT=5000
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-actual-service-role-key
```

> [!WARNING]
> The `SUPABASE_SERVICE_ROLE_KEY` must **NEVER** be committed to Git or exposed in client-side frontend code (never prefix with `NEXT_PUBLIC_` or `VITE_`).

### 4. Run the Server
* **Development mode** (with auto-reload on Node 18+):
  ```bash
  npm run dev
  ```
* **Production mode**:
  ```bash
  npm start
  ```
The server will start on `http://localhost:5000`.

---

## API Endpoints

### 1. Health Check
* **Method:** `GET /api/health`
* **Description:** Verifies server status and checks whether database credentials are configured without exposing keys.
* **Response (200 OK):**
```json
{
  "status": "healthy",
  "service": "ReturnIQ Backend API",
  "database_configured": true,
  "timestamp": "2026-10-09T20:50:00.000Z"
}
```

---

### 2. List Returns & Quality Alerts
* **Method:** `GET /api/returns`
* **Description:** Fetches logged returned inventory joined with product and batch information, alongside open supplier defect alerts.
* **Response (200 OK):**
```json
{
  "returns": [
    {
      "id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "return_tracking_id": "RET-2026-HB09-01",
      "returned_units": 40,
      "item_grade": "Grade B",
      "is_confirmed_defect": true,
      "vendor_eligible_units": 24,
      "intake_status": "received",
      "products": { "sku": "WH-AERO-01", "name": "AeroTune Wireless Headphones" },
      "supplier_batches": { "batch_code": "HB-09" }
    }
  ],
  "open_alerts": [
    {
      "id": "e2c045b8-508b-4b14-8f43-7f66a014e7a8",
      "batch_code": "HB-09",
      "severity": "critical",
      "defect_rate_pct": 12.00,
      "defect_threshold_pct": 5.00
    }
  ]
}
```

---

### 3. Evaluate Recovery Options
* **Method:** `POST /api/routes/evaluate`
* **Description:** Executes PostgreSQL function `fn_evaluate_recovery_options` to compare the 4 pathways (Restock, Return to Vendor, Refurbish & Resell, Liquidation).
* **Request Body:**
```json
{
  "return_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
}
```
* **Response (200 OK):** Array of 4 evaluated routes with unit gross recovery, refurb costs, net value in INR, eligibility status, and rationale.

---

### 4. Submit Multi-Route Split Recovery Plan
* **Method:** `POST /api/plans`
* **Description:** Submits a recovery plan header and inserts split route allocations.
* **Atomicity Limitation:** Standard PostgREST REST calls do not execute in a single database transaction. This server uses compensating cleanup (deleting the header if allocation insertion fails) as a best-effort mitigation. If the server crashes or loses connectivity between steps, orphaned records will persist. The full production implementation requires wrapping this in a single PostgreSQL RPC transaction.
* **Request Body:**
```json
{
  "returned_inventory_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "plan_code": "PLAN-HB09-DEMO",
  "allocations": [
    {
      "route": "return_to_vendor",
      "allocated_units": 24,
      "recovery_channel_type": "supplier_credit",
      "unit_gross_recovery_inr": 840.00,
      "unit_cost_inr": 0.00,
      "estimated_days_to_realize": 14,
      "allocation_rationale": "Claim 60% vendor credit under active 30-day warranty window"
    },
    {
      "route": "refurbish_and_resell",
      "allocated_units": 16,
      "recovery_channel_type": "cash",
      "unit_gross_recovery_inr": 1875.00,
      "unit_cost_inr": 250.00,
      "estimated_days_to_realize": 5,
      "allocation_rationale": "Refurbish 16 units for high-demand retail resale"
    }
  ]
}
```
* **Response (201 Created):** Returns created plan and allocation records with database-calculated stored totals.

---

### 5. Approve or Reject Recovery Plan
* **Method:** `PATCH /api/plans/:id`
* **Description:** Changes plan status to `approved` or `rejected`.
* **Security & Authorization Rules:**
  - `manager_approved_by` is an unverified audit metadata string from client input; it is **NOT** proof of caller identity or authorization.
  - Query parameters (e.g. `?role=manager`) or custom demo headers (`x-demo-role`) are **NOT** authentication or authorization.
  - Client-supplied `approved_at` timestamps are strictly ignored and overwritten by server clock (`new Date().toISOString()`).
* **Request Body (Approval):**
```json
{
  "status": "approved",
  "manager_approved_by": "Priya Sharma (Operations Head)",
  "manager_notes": "Split strategy confirmed: maximized vendor credit and prioritized high-velocity resale."
}
```

---

### 6. Executive Recovery Pipeline Analytics
* **Method:** `GET /api/analytics/pipeline`
* **Description:** Queries SQL views `vw_recovery_pipeline_summary` and `vw_vendor_compliance_and_rtv`.
* **Response (200 OK):**
```json
{
  "pipeline_summary": {
    "total_plans": 1,
    "approved_plans_count": 1,
    "gross_cash_recovery_inr": 30000.00,
    "cash_recovery_costs_inr": 4000.00,
    "net_cash_recovery_inr": 26000.00,
    "net_supplier_credit_inr": 20160.00,
    "total_combined_recovery_inr": 46160.00,
    "rtv_units": 24,
    "refurbish_units": 16,
    "liquidation_units": 0,
    "restock_units": 0
  },
  "vendor_compliance": [...]
}
```

---

## Security & Deployment Boundaries

### 1. Prototype Scope (Localhost Only)
* This server is designed strictly for local evaluation and pairing with a frontend running on `localhost`.
* **DO NOT** expose this server publicly or deploy to production in its current form.

### 2. Authorization Requirements Before Public Deployment
* In this prototype, endpoints lack authentication middleware.
* **Before public deployment:** The `PATCH /api/plans/:id` endpoint must be protected by real authentication (e.g. verifying a Supabase Auth JWT) and role-based authorization ensuring `auth.uid()` possesses an authorized Operations Manager role.
* Neither `manager_approved_by` in the request body, query parameters, nor custom headers (`x-demo-role`) can be treated as security controls.

### 3. Plan Creation Atomicity Limitations
* Plan creation currently uses a two-step sequence (`recovery_plans` insert followed by `recovery_allocations` insert) with a compensating delete if allocations fail.
* **Compensating delete is NOT a true ACID database transaction:**
  1. If the Node.js process crashes, reboots, or loses network connectivity between the two operations, the compensating delete will never run. An orphaned plan header in `pending_approval` will remain permanently in the database.
  2. Between the header insert and allocation insert/delete, concurrent queries can observe the incomplete plan.
  3. If the compensating DELETE itself fails or times out, partial data remains.
* **Production Resolution:** True atomicity requires wrapping plan creation and allocations inside a single PostgreSQL stored procedure (RPC) executing in a single `BEGIN ... COMMIT` transaction.

---

## Offline / Local Verification Instructions

These checks can be performed locally without installing packages, connecting to Supabase, or modifying the database:

### 1. Allowed CORS Origin
Send an HTTP request with an `Origin` matching `ALLOWED_ORIGINS` (e.g. `http://localhost:3000`):
```bash
curl -i -X GET http://localhost:5000/api/health -H "Origin: http://localhost:3000"
```
* **Expected Result:** HTTP `200 OK` with header `Access-Control-Allow-Origin: http://localhost:3000`.

### 2. Rejected CORS Origin
Send an HTTP request with an unlisted `Origin`:
```bash
curl -i -X GET http://localhost:5000/api/health -H "Origin: http://unauthorized-domain.com"
```
* **Expected Result:** HTTP `403 Forbidden` with body:
```json
{
  "error": "Forbidden",
  "message": "Origin not allowed by CORS policy"
}
```

### 3. Request Without an Origin (Local CLI Tools)
Send a local request without an `Origin` header (e.g. curl command-line health check):
```bash
curl -i http://localhost:5000/api/health
```
* **Expected Result:** HTTP `200 OK` with JSON health body.
* *Note:* Absence of an `Origin` header enables local CLI tooling and health probes, but does NOT grant authentication or bypass route logic.

### 4. Health Endpoint with No Database Credentials
Start the server with an empty `.env` or placeholder values:
```bash
curl -i http://localhost:5000/api/health
```
* **Expected Result:** HTTP `200 OK` with:
```json
{
  "status": "healthy",
  "service": "ReturnIQ Backend API",
  "database_configured": false,
  "timestamp": "..."
}
```

### 5. Database Endpoints Return 503 When Credentials Are Absent
Query any database-dependent endpoint when Supabase is unconfigured:
```bash
curl -i http://localhost:5000/api/returns
```
or
```bash
curl -i http://localhost:5000/api/analytics/pipeline
```
* **Expected Result:** HTTP `503 Service Unavailable` with body:
```json
{
  "error": "Database service unavailable",
  "message": "Supabase connection is not configured. Please set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in your local .env file."
}
```
*(Confirms that no fake success responses are returned and that unconfigured state is handled gracefully).*

