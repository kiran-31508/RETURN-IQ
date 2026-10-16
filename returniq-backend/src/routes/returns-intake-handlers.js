import { validateCreateReturn } from "./returns-intake-validation.js";

function sendDbError(res, error, action) {
  // Keep database internals out of API responses. Log only the code and operation.
  console.error(`[returns-intake] ${action} failed`, { code: error?.code ?? "unknown" });
  if (error?.code === "23505") return res.status(409).json({ error: "A return with this tracking ID already exists." });
  if (error?.code === "23503") return res.status(400).json({ error: "A referenced product or batch no longer exists." });
  if (error?.code === "23514" || error?.code === "22P02" || error?.code === "22007") return res.status(400).json({ error: "The supplied values do not satisfy database validation rules." });
  return res.status(500).json({ error: "The request could not be completed. Check the server logs and database connection." });
}

export function createOptionsHandler(supabase) {
  return async function getReturnOptions(_req, res) {
    try {
      const [productsResult, batchesResult] = await Promise.all([
        supabase.from("products").select("id,name,sku,supplier_id").order("name", { ascending: true }),
        supabase.from("supplier_batches").select("id,batch_code,product_id,supplier_id,vendor_return_deadline").order("batch_code", { ascending: true }),
      ]);
      if (productsResult.error) return sendDbError(res, productsResult.error, "load products");
      if (batchesResult.error) return sendDbError(res, batchesResult.error, "load batches");
      const products = productsResult.data ?? [];
      const batches = batchesResult.data ?? [];
      const supplierIds = [...new Set([...products, ...batches].map(row => row.supplier_id).filter(Boolean))];
      let suppliers = [];
      if (supplierIds.length) {
        const supplierResult = await supabase.from("suppliers").select("id,name,code").in("id", supplierIds);
        if (supplierResult.error) return sendDbError(res, supplierResult.error, "load suppliers");
        suppliers = supplierResult.data ?? [];
      }
      const productById = new Map(products.map(p => [p.id, p]));
      const supplierById = new Map(suppliers.map(s => [s.id, s]));
      return res.status(200).json({
        products: products.map(p => ({ id: p.id, name: p.name, sku: p.sku, supplier_id: p.supplier_id, supplier_name: supplierById.get(p.supplier_id)?.name ?? null })),
        batches: batches.map(b => ({
          id: b.id,
          batch_code: b.batch_code,
          product_id: b.product_id,
          supplier_id: b.supplier_id,
          supplier_name: supplierById.get(b.supplier_id)?.name ?? null,
          product_name: productById.get(b.product_id)?.name ?? null,
          vendor_return_deadline: b.vendor_return_deadline ?? null
        })),
      });
    } catch {
      return res.status(500).json({ error: "Unable to load intake options." });
    }
  };
}

export function createReturnHandler(supabase) {
  return async function createReturn(req, res) {
    const { errors, value } = validateCreateReturn(req.body);
    if (errors.length) return res.status(400).json({ error: "Validation failed.", details: errors.join(" "), validation_errors: errors });

    try {
      const [productResult, batchResult] = await Promise.all([
        supabase.from("products").select("id,supplier_id").eq("id", value.product_id).maybeSingle(),
        supabase.from("supplier_batches").select("id,product_id,supplier_id").eq("id", value.batch_id).maybeSingle(),
      ]);
      if (productResult.error) return sendDbError(res, productResult.error, "validate product");
      if (batchResult.error) return sendDbError(res, batchResult.error, "validate batch");
      if (!productResult.data) return res.status(404).json({ error: "The selected product was not found." });
      if (!batchResult.data) return res.status(404).json({ error: "The selected supplier batch was not found." });
      if (batchResult.data.product_id !== productResult.data.id) return res.status(400).json({ error: "The selected supplier batch does not belong to the selected product." });
      if (productResult.data.supplier_id && batchResult.data.supplier_id && productResult.data.supplier_id !== batchResult.data.supplier_id) {
        return res.status(400).json({ error: "The selected product and supplier batch do not belong to the same supplier." });
      }

      const { data, error } = await supabase.from("returned_inventory").insert(value).select("*").single();
      if (error) return sendDbError(res, error, "insert return");
      return res.status(201).json({ return: data });
    } catch {
      return res.status(500).json({ error: "The return could not be saved due to an unexpected server error." });
    }
  };
}
