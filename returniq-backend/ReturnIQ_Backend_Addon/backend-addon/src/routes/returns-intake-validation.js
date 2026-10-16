const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const GRADES = new Map([["a", "Grade A"], ["grade a", "Grade A"], ["b", "Grade B"], ["grade b", "Grade B"], ["c", "Grade C"], ["grade c", "Grade C"], ["d", "Grade D"], ["grade d", "Grade D"]]);
const STATUSES = new Set(["received", "inspected", "allocated", "completed"]);

export function normalizeGrade(value) {
  return GRADES.get(String(value ?? "").trim().toLowerCase()) ?? null;
}

export function validateCreateReturn(input) {
  const errors = [];
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return { errors: ["Request body must be a JSON object."], value: null };
  }
  const tracking = typeof input.return_tracking_id === "string" ? input.return_tracking_id.trim() : "";
  const reason = typeof input.return_reason === "string" ? input.return_reason.trim() : "";
  const productId = typeof input.product_id === "string" ? input.product_id.trim() : "";
  const batchId = typeof input.batch_id === "string" ? input.batch_id.trim() : "";
  const units = input.returned_units;
  const vendorUnits = input.vendor_eligible_units === undefined ? 0 : input.vendor_eligible_units;
  const itemGrade = normalizeGrade(input.item_grade ?? input.condition_grade);
  const returnDate = input.return_date;
  const status = input.intake_status === undefined ? "received" : input.intake_status;

  if (!tracking) errors.push("return_tracking_id is required.");
  else if (tracking.length > 120) errors.push("return_tracking_id must be 120 characters or fewer.");
  if (!UUID_RE.test(productId)) errors.push("product_id must be a valid UUID.");
  if (!UUID_RE.test(batchId)) errors.push("batch_id must be a valid UUID.");
  if (!Number.isInteger(units) || units <= 0) errors.push("returned_units must be a positive integer.");
  if (!itemGrade) errors.push("item_grade must be Grade A, Grade B, Grade C, or Grade D (A/B/C/D are also accepted).");
  if (!reason) errors.push("return_reason is required.");
  else if (reason.length > 3000) errors.push("return_reason must be 3000 characters or fewer.");
  if (!Number.isInteger(vendorUnits) || vendorUnits < 0) errors.push("vendor_eligible_units must be a non-negative integer.");
  if (Number.isInteger(units) && Number.isInteger(vendorUnits) && vendorUnits > units) errors.push("vendor_eligible_units cannot exceed returned_units.");
  if (input.is_confirmed_defect !== undefined && typeof input.is_confirmed_defect !== "boolean") errors.push("is_confirmed_defect must be a boolean.");
  if (returnDate !== undefined && returnDate !== null && returnDate !== "") {
    const validDate = typeof returnDate === "string" && /^\d{4}-\d{2}-\d{2}$/.test(returnDate) && !Number.isNaN(Date.parse(`${returnDate}T00:00:00.000Z`)) && new Date(`${returnDate}T00:00:00.000Z`).toISOString().slice(0, 10) === returnDate;
    if (!validDate) errors.push("return_date must be a valid YYYY-MM-DD date.");
  }
  if (!STATUSES.has(status)) errors.push("intake_status must be received, inspected, allocated, or completed.");
  if (input.notes !== undefined && input.notes !== null && typeof input.notes !== "string") errors.push("notes must be a string when provided.");
  if (typeof input.notes === "string" && input.notes.length > 3000) errors.push("notes must be 3000 characters or fewer.");

  if (errors.length) return { errors, value: null };
  const value = {
    return_tracking_id: tracking,
    product_id: productId,
    batch_id: batchId,
    returned_units: units,
    item_grade: itemGrade,
    return_reason: reason,
    is_confirmed_defect: input.is_confirmed_defect ?? false,
    vendor_eligible_units: vendorUnits,
    intake_status: status,
  };
  if (returnDate) value.return_date = returnDate;
  if (input.notes?.trim()) value.notes = input.notes.trim();
  return { errors: [], value };
}

