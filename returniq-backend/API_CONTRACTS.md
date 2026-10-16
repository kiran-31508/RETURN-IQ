# ReturnIQ Backend API Contracts & Reverse Logistics Architecture

**Event:** CYPHER 2026 Hackathon  
**Target Domain:** Value Recovery from Returned Inventory & Supplier Quality Defect Detection  
**Currency Standard:** INR (`₹`)  
**Security Standard:** Server-Side Mediated (RLS enabled, zero public browser access)

---

## 1. System Architecture & Server-Side Security Model

```
┌────────────────────────────────────────────────────────┐
│           Future ReturnIQ Frontend Dashboard           │
│   (Manager Approval Queue, Route Comparison, Alerts)   │
└───────────────────────────┬────────────────────────────┘
                            │ HTTPS (Custom Auth / Session)
                            ▼
┌────────────────────────────────────────────────────────┐
│               Server-Side API Layer                    │
│    (Next.js App Router Server Actions / Express API)   │
│   * Securely holds SUPABASE_SERVICE_ROLE_KEY           │
│   * Enforces business rules & role-based approvals     │
└───────────────────────────┬────────────────────────────┘
                            │ Private PostgreSQL Connection (Bypasses RLS)
                            ▼
┌────────────────────────────────────────────────────────┐
│                  Supabase PostgreSQL 17                │
│   - RLS Enabled on all 7 tables (Deny all anon keys)   │
│   - Triggers: Allocation limits, Defect alerts         │
│   - Function: fn_evaluate_recovery_options             │
│   - Zero Double-Counting Analytical Views              │
└────────────────────────────────────────────────────────┘
```

### Security Configuration
1. In your backend `.env.local` / environment configuration:
   ```env
   # SERVER-SIDE ONLY (NEVER prefix with NEXT_PUBLIC_ or VITE_)
   SUPABASE_URL="https://anuwzafozptnljnlvlzw.supabase.co"
   SUPABASE_SERVICE_ROLE_KEY="eyJh..." 
   ```
2. In Supabase, all tables have `ROW LEVEL SECURITY` turned ON with **no** public `anon` policies. If an attacker opens browser dev tools and attempts to query `rest/v1/recovery_plans`, Supabase rejects it with a `401 / 403 Forbidden`.

---

## 2. API Contracts: Intake, Route Evaluation & Batch Splitting

### A. Return Intake Options (Form Population)
Provides the active catalog product and supplier-batch references needed to populate the frontend New Return intake form without creating or mutating data. The route queries existing database records; no mock options are inserted and options may be empty if no matching rows exist.

* **Endpoint:** `GET /api/returns/options`
* **Response Contract (200 OK):**
```json
{
  "products": [
    {
      "id": "b0000000-0000-0000-0000-000000000001",
      "name": "AeroTune Wireless Headphones",
      "sku": "WH-AERO-01",
      "supplier_id": "a0000000-0000-0000-0000-000000000001",
      "supplier_name": "SonicWave Electronics Ltd"
    }
  ],
  "batches": [
    {
      "id": "c0000000-0000-0000-0000-000000000001",
      "batch_code": "HB-09",
      "product_id": "b0000000-0000-0000-0000-000000000001",
      "supplier_id": "a0000000-0000-0000-0000-000000000001",
      "supplier_name": "SonicWave Electronics Ltd",
      "product_name": "AeroTune Wireless Headphones",
      "vendor_return_deadline": "2026-10-29"
    }
  ]
}
```

---

### B. New Return Intake (Record Creation)
Creates one incoming returned merchandise intake record into PostgreSQL table `public.returned_inventory` using the existing server-side Supabase client. Enforces referential integrity between `product_id` and `batch_id`, normalizes item grade to check constraint values, and allows existing PostgreSQL database triggers (`trg_check_batch_defects`) to compute supplier quality defect alerts automatically. Never show UI success until the HTTP `201` response arrives. These endpoints do not create recovery plans and do not apply migrations or seed data.

* **Endpoint:** `POST /api/returns`
* **Content-Type:** `application/json`
* **Request Payload Schema:**
```json
{
  "return_tracking_id": "RET-NEW-001",
  "product_id": "b0000000-0000-0000-0000-000000000001",
  "batch_id": "c0000000-0000-0000-0000-000000000001",
  "returned_units": 10,
  "item_grade": "Grade B",
  "return_reason": "Audio issue",
  "return_date": "2026-10-10",
  "is_confirmed_defect": false,
  "vendor_eligible_units": 0,
  "intake_status": "received",
  "notes": "Verified at intake dock"
}
```
* **Validation Rules:**
  * `return_tracking_id` (string, required): Non-empty unique tracking ID (<= 120 chars). Duplicate yields HTTP 409.
  * `product_id` (UUID, required): Canonical 8-4-4-4-12 hex UUID referencing an existing row in `public.products`.
  * `batch_id` (UUID, required): Canonical 8-4-4-4-12 hex UUID referencing an existing row in `public.supplier_batches` that belongs to `product_id`. Mismatch yields HTTP 400. Missing row yields HTTP 404.
  * `returned_units` (integer, required): Positive integer (> 0).
  * `item_grade` (string, required): Accepts `'A'`, `'B'`, `'C'`, `'D'` (case-insensitive) or exact labels `'Grade A'` through `'Grade D'`. Automatically normalized to database constraint.
  * `return_reason` (string, required): Non-empty description (<= 3000 chars).
  * `return_date` (string, optional): ISO date string (`YYYY-MM-DD`). Defaults to database default / `CURRENT_DATE`.
  * `is_confirmed_defect` (boolean, optional): Default `false`. When `true` with `vendor_eligible_units > 0`, database trigger automatically evaluates supplier alert thresholds.
  * `vendor_eligible_units` (integer, optional): Non-negative integer, default `0`. Cannot exceed `returned_units`.
  * `intake_status` (string, optional): One of `'received'`, `'inspected'`, `'allocated'`, `'completed'`. Default `'received'`.
  * `notes` (string, optional): Freeform intake notes (<= 3000 chars).
* **Success Response Contract (201 Created):**
```json
{
  "return": {
    "id": "d0000000-0000-0000-0000-000000000001",
    "return_tracking_id": "RET-NEW-001",
    "product_id": "b0000000-0000-0000-0000-000000000001",
    "batch_id": "c0000000-0000-0000-0000-000000000001",
    "returned_units": 10,
    "item_grade": "Grade B",
    "return_reason": "Audio issue",
    "return_date": "2026-10-10",
    "is_confirmed_defect": false,
    "vendor_eligible_units": 0,
    "intake_status": "received",
    "notes": "Verified at intake dock",
    "created_at": "2026-10-10T06:30:00.000Z"
  }
}
```
  *Note:* The `return` object contains the actual row returned by Supabase.
* **Error Response Contracts:**
  * **400 Bad Request:** Invalid JSON data, failed validation, mismatched product/batch, or database constraint violation.
    ```json
    {
      "error": "The selected supplier batch does not belong to the selected product."
    }
    ```
  * **404 Not Found:** Referenced product or batch not found.
    ```json
    {
      "error": "The selected product was not found."
    }
    ```
  * **409 Conflict:** Duplicate tracking ID or unique key conflict.
    ```json
    {
      "error": "A return with this tracking ID already exists."
    }
    ```
  * **500 Internal Server Error:** Unexpected server or database execution failure with zero credentials, tokens, or raw SQL exposed.
    ```json
    {
      "error": "The request could not be completed. Check the server logs and database connection."
    }
    ```

---

### C. Route Evaluation Engine (Comparing the 4 Recovery Routes)
Evaluates Restock, Refurbish & Resell, Return to Vendor (RTV), and Liquidation for any return intake record.

* **RPC Endpoint:** `POST /rest/v1/rpc/fn_evaluate_recovery_options`
* **Request Payload:**
```json
{
  "p_return_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
}
```
* **Response Contract:**
```json
[
  {
    "route": "restock",
    "is_eligible": false,
    "ineligibility_reason": "Direct restock is only permissible for Grade A (like-new) condition.",
    "recovery_channel_type": "cash",
    "eligible_units": 0,
    "unit_gross_recovery_inr": 2500.00,
    "unit_cost_inr": 0.00,
    "unit_net_recovery_inr": 2500.00,
    "potential_total_net_inr": 0.00,
    "estimated_days_to_realize": 1,
    "explanation": "Item condition does not meet Grade A standard."
  },
  {
    "route": "return_to_vendor",
    "is_eligible": true,
    "ineligibility_reason": null,
    "recovery_channel_type": "supplier_credit",
    "eligible_units": 24,
    "unit_gross_recovery_inr": 840.00,
    "unit_cost_inr": 0.00,
    "unit_net_recovery_inr": 840.00,
    "potential_total_net_inr": 20160.00,
    "estimated_days_to_realize": 14,
    "explanation": "Eligible for 60% vendor credit (20 days remaining in window)."
  },
  {
    "route": "refurbish_and_resell",
    "is_eligible": true,
    "ineligibility_reason": null,
    "recovery_channel_type": "cash",
    "eligible_units": 40,
    "unit_gross_recovery_inr": 1875.00,
    "unit_cost_inr": 250.00,
    "unit_net_recovery_inr": 1625.00,
    "potential_total_net_inr": 65000.00,
    "estimated_days_to_realize": 5,
    "explanation": "Resale at 75% of MRP (₹1875.00) yielding ₹1625.00 net margin after ₹250.00 refurb cost."
  },
  {
    "route": "liquidation",
    "is_eligible": true,
    "ineligibility_reason": null,
    "recovery_channel_type": "cash",
    "eligible_units": 40,
    "unit_gross_recovery_inr": 490.00,
    "unit_cost_inr": 0.00,
    "unit_net_recovery_inr": 490.00,
    "potential_total_net_inr": 19600.00,
    "estimated_days_to_realize": 3,
    "explanation": "Instant B2B liquidation recovery at 35% of cost price (₹490.00/unit)."
  }
]
```

---

### B. Batch Splitting: Submitting a Multi-Route Recovery Plan
Allows splitting a single returned batch across multiple routes (e.g., 24 units to RTV and 16 units to Refurbishment).

* **1. Create Recovery Plan Header:**
  * `POST /rest/v1/recovery_plans`
  * Payload:
    ```json
    {
      "returned_inventory_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "plan_code": "PLAN-HB09-2026-01",
      "status": "pending_approval"
    }
    ```

* **2. Allocate Split Quantities:**
  * `POST /rest/v1/recovery_allocations`
  * Payload:
    ```json
    [
      {
        "plan_id": "...",
        "route": "return_to_vendor",
        "allocated_units": 24,
        "recovery_channel_type": "supplier_credit",
        "unit_gross_recovery_inr": 840.00,
        "unit_cost_inr": 0.00,
        "estimated_days_to_realize": 14,
        "allocation_rationale": "Claim 60% vendor credit under active 30-day warranty window"
      },
      {
        "plan_id": "...",
        "route": "refurbish_and_resell",
        "allocated_units": 16,
        "recovery_channel_type": "cash",
        "unit_gross_recovery_inr": 1875.00,
        "unit_cost_inr": 250.00,
        "estimated_days_to_realize": 5,
        "allocation_rationale": "Refurbish 16 units to capture high retail demand at ₹1,875 resale"
      }
    ]
    ```
  > [!NOTE]
  > Database trigger `trg_validate_recovery_allocation` strictly enforces that the sum of `allocated_units` cannot exceed the 40 returned units, and RTV units cannot exceed `vendor_eligible_units` (24). Any higher number triggers an immediate SQL exception.

* **3. Manager Decision / Approval:**
  * `PATCH /rest/v1/recovery_plans?id=eq.{id}`
  * Payload:
    ```json
    {
      "status": "approved",
      "manager_approved_by": "Priya Sharma (Operations Head)",
      "manager_notes": "Split strategy confirmed: maximized vendor credit and prioritized high-velocity resale.",
      "approved_at": "2026-10-09T19:30:00Z"
    }
    ```

---

### C. Supplier Quality & RTV Compliance (View Contract)
* **Endpoint:** `GET /rest/v1/vw_vendor_compliance_and_rtv?batch_code=eq.HB-09`
* **Response Contract:**
```json
[
  {
    "batch_id": "...",
    "batch_code": "HB-09",
    "supplier_name": "SonicWave Electronics Ltd",
    "sku": "WH-AERO-01",
    "product_name": "AeroTune Wireless Headphones",
    "units_received": 200,
    "units_returned": 40,
    "confirmed_defect_units": 24,
    "confirmed_defect_rate_pct": 12.00,
    "defect_threshold_pct": 5.00,
    "vendor_window_basis_date": "2026-09-29",
    "vendor_return_deadline": "2026-10-29",
    "is_vendor_window_active": true,
    "days_remaining_in_window": 20,
    "total_vendor_eligible_units": 24,
    "potential_vendor_credit_inr": 20160.00
  }
]
```

---

### D. Executive Recovery Pipeline View Contract (Zero Double-Counting)
* **Endpoint:** `GET /rest/v1/vw_recovery_pipeline_summary`
* **Response Contract:**
```json
[
  {
    "total_plans": 1,
    "approved_plans_count": 1,
    "pending_approval_count": 0,
    "gross_cash_recovery_inr": 30000.00,
    "cash_recovery_costs_inr": 4000.00,
    "net_cash_recovery_inr": 26000.00,
    "net_supplier_credit_inr": 20160.00,
    "total_combined_recovery_inr": 46160.00,
    "rtv_units": 24,
    "refurbish_units": 16,
    "liquidation_units": 0,
    "restock_units": 0
  }
]
```

---

## 3. CYPHER 2026 Hackathon Test Scenario Breakdown

| Attribute | Parameter Value | Source / Calculation |
|---|---|---|
| Product | AeroTune Wireless Headphones (`WH-AERO-01`) | Catalog |
| Batch | `HB-09` (200 units received) | Supplier Batches |
| MRP | `₹2,500.00` | Base Price |
| Landed Cost | `₹1,400.00` | Purchase Price |
| Total Returns | 40 units (Grade B) | Returned Inventory |
| Defect Signal | 24 units confirmed manufacturing defect | 12% defect rate > 5% threshold (Alert: `critical`) |
| Vendor Window | Basis Date: -10 days, Deadline: +20 days | `is_vendor_window_active` = `true` (20 days remaining) |
| Route 1: RTV | 24 units @ 60% of ₹1,400 | **₹20,160.00 Supplier Credit** (Time: 14 days) |
| Route 2: Refurbish | 16 units @ ₹1,875 (75% MRP) - ₹250 refurb cost | **₹26,000.00 Cash Recovery** (Time: 5 days) |
| **Combined Net Value** | 24 RTV + 16 Refurbished | **₹46,160.00 Total Recovered** |
