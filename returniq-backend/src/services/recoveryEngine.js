import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { isSupabaseConfigured } from '../supabase.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Benchmark snapshot context from README.md: morning of 2026-11-16; history up to 2026-11-15
export const SNAPSHOT_DATE_STR = '2026-11-16';
export const SNAPSHOT_DATE = new Date('2026-11-16T00:00:00Z');

function parseCSVLine(line) {
  const result = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === ',' && !inQuotes) {
      result.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  result.push(current.trim());
  return result;
}

function loadCSV(filename) {
  const filePath = path.resolve(__dirname, '../../data/gadgetbay', filename);
  if (!fs.existsSync(filePath)) return [];
  const lines = fs.readFileSync(filePath, 'utf-8').replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').filter(l => l.trim().length > 0);
  const header = parseCSVLine(lines[0]);
  return lines.slice(1).map(l => parseCSVLine(l));
}

// In-memory fallback caches
let dataLoaded = false;
const productsMap = new Map();
const inventoryMap = new Map();
const vendorTermsMap = new Map();
const refurbMap = new Map();
const liquidationMap = new Map();
const returnsMap = new Map();
const allReturnsList = [];

export function initDataset() {
  if (dataLoaded) return;

  const pRows = loadCSV('products.csv');
  pRows.forEach(r => {
    productsMap.set(r[0], {
      sku: r[0],
      product: r[1],
      category: r[2],
      cost_price: parseFloat(r[3]),
      selling_price: parseFloat(r[4]),
      supplier: r[5]
    });
  });

  const iRows = loadCSV('inventory.csv');
  iRows.forEach(r => {
    inventoryMap.set(r[0], {
      sku: r[0],
      new_stock: parseInt(r[1], 10),
      avg_daily_demand: parseFloat(r[2])
    });
  });

  const vRows = loadCSV('vendor_terms.csv');
  vRows.forEach(r => {
    vendorTermsMap.set(r[1], {
      supplier: r[0],
      sku: r[1],
      rtv_allowed: r[2].toLowerCase() === 'yes',
      credit_pct: parseFloat(r[3]),
      window_days: parseInt(r[4], 10)
    });
  });

  const rfRows = loadCSV('refurbishment.csv');
  rfRows.forEach(r => {
    refurbMap.set(r[0], {
      category: r[0],
      refurb_cost: parseFloat(r[1]),
      days_required: parseInt(r[2], 10),
      resale_pct_of_new: parseFloat(r[3])
    });
  });

  const lqRows = loadCSV('liquidation.csv');
  lqRows.forEach(r => {
    liquidationMap.set(`${r[0]}_${r[1]}`, parseFloat(r[2]));
  });

  const retRows = loadCSV('returns.csv');
  retRows.forEach(r => {
    const prod = productsMap.get(r[2]) || {};
    const item = {
      id: r[0],
      return_id: r[0],
      return_tracking_id: r[0],
      date_received: r[1],
      return_date: r[1],
      sku: r[2],
      product_sku: r[2],
      product_name: prod.product || r[2],
      category: prod.category || 'General',
      supplier_name: prod.supplier || 'Unknown Supplier',
      batch_code: r[3],
      reason_code: r[4],
      return_reason: r[4],
      condition_grade: r[5],
      item_grade: r[5],
      status: r[6],
      intake_status: r[6],
      returned_units: 1,
      cost_price: prod.cost_price,
      selling_price: prod.selling_price
    };
    returnsMap.set(r[0], item);
    allReturnsList.push(item);
  });

  dataLoaded = true;
}

initDataset();

export function getAllReturns() {
  initDataset();
  return allReturnsList;
}

export function getReturnById(returnId) {
  initDataset();
  return returnsMap.get(returnId) || null;
}

export function getAllProducts() {
  initDataset();
  return Array.from(productsMap.values()).map(p => ({
    ...p,
    inventory: inventoryMap.get(p.sku) || { new_stock: 0, avg_daily_demand: 0 },
    vendor_terms: vendorTermsMap.get(p.sku) || null
  }));
}

/**
 * Pure calculation function for recovery pathways.
 * Evaluates Restock, RTV, Refurbish, and Liquidation.
 */
export function calculateRecoveryRoutes(params) {
  const {
    sku,
    condition_grade,
    date_received,
    cost_price,
    selling_price,
    category,
    new_stock,
    avg_daily_demand,
    rtv_allowed,
    credit_pct,
    window_days,
    refurb_cost,
    days_required,
    resale_pct_of_new,
    liq_pct,
    returned_units = 1,
    dataSource = 'local_csv_fallback'
  } = params;

  const grade = (condition_grade || 'B').replace(/^Grade\s*/i, '').toUpperCase();
  const costPrice = Number(cost_price) || 0;
  const sellingPrice = Number(selling_price) || 0;
  const stock = Number(new_stock) || 0;
  const demand = Number(avg_daily_demand) || 0;
  const daysOfSupply = demand > 0 ? (stock / demand) : 999;

  // Window calculation relative to benchmark snapshot 2026-11-16
  const recDate = date_received ? new Date(date_received + 'T00:00:00Z') : SNAPSHOT_DATE;
  const daysElapsed = Math.max(0, Math.floor((SNAPSHOT_DATE - recDate) / (1000 * 60 * 60 * 24)));
  const daysRemaining = (Number(window_days) || 0) - daysElapsed;

  const options = [];

  // 1. Restock Route
  {
    const unitGross = sellingPrice;
    const unitCost = 0;
    const unitNet = unitGross;
    let isEligible = false;
    let ineligibilityReason = null;
    let explanation = '';

    if (grade !== 'A') {
      isEligible = false;
      ineligibilityReason = 'Direct restock is only permissible for Grade A (like-new) condition.';
      explanation = `Item is Grade ${grade}; cannot be restocked as new inventory.`;
    } else if (demand === 0) {
      isEligible = false;
      ineligibilityReason = 'Zero sales demand velocity. Restocking would create stagnant inventory.';
      explanation = 'Demand is 0 units/day; holding capital risk.';
    } else if (daysOfSupply > 90) {
      isEligible = false;
      ineligibilityReason = `Excessive stock supply (${daysOfSupply.toFixed(0)} days of supply). Overstock holding risk.`;
      explanation = `Current stock (${stock}) exceeds 90 days demand.`;
    } else {
      isEligible = true;
      explanation = `Grade A item eligible for immediate inventory replenishment. (${daysOfSupply.toFixed(0)} days existing supply).`;
    }

    const eligibleUnits = isEligible ? returned_units : 0;
    options.push({
      route: 'restock',
      is_eligible: isEligible,
      ineligibility_reason: ineligibilityReason,
      recovery_channel_type: 'cash',
      eligible_units: eligibleUnits,
      unit_gross_recovery_inr: unitGross,
      unit_cost_inr: unitCost,
      unit_net_recovery_inr: unitNet,
      potential_total_net_inr: isEligible ? eligibleUnits * unitNet : 0,
      estimated_days_to_realize: 1,
      explanation,
      data_source: dataSource
    });
  }

  // 2. Return to Vendor (RTV)
  {
    const creditFraction = Number(credit_pct) || 0;
    const unitGross = Math.round(costPrice * creditFraction);
    const unitCost = 0;
    const unitNet = unitGross;
    let isEligible = false;
    let ineligibilityReason = null;
    let explanation = '';

    if (!rtv_allowed) {
      isEligible = false;
      ineligibilityReason = 'Supplier contract does not permit Return to Vendor for this SKU.';
      explanation = 'Supplier terms explicitly set rtv_allowed = No.';
    } else if (daysRemaining < 0) {
      isEligible = false;
      ineligibilityReason = `Vendor return window expired (${Math.abs(daysRemaining)} days past the ${window_days}-day limit).`;
      explanation = `Received ${daysElapsed} days prior to snapshot date ${SNAPSHOT_DATE_STR}; deadline was ${window_days} days.`;
    } else {
      isEligible = true;
      explanation = `Eligible for ${(creditFraction * 100).toFixed(0)}% vendor credit (${daysRemaining} days remaining in window).`;
    }

    const eligibleUnits = isEligible ? returned_units : 0;
    options.push({
      route: 'return_to_vendor',
      is_eligible: isEligible,
      ineligibility_reason: ineligibilityReason,
      recovery_channel_type: 'supplier_credit',
      eligible_units: eligibleUnits,
      unit_gross_recovery_inr: unitGross,
      unit_cost_inr: unitCost,
      unit_net_recovery_inr: unitNet,
      potential_total_net_inr: isEligible ? eligibleUnits * unitNet : 0,
      estimated_days_to_realize: 14,
      explanation,
      data_source: dataSource
    });
  }

  // 3. Refurbish and Resell
  {
    const resaleFraction = Number(resale_pct_of_new) || 0.75;
    const refurbCost = Number(refurb_cost) || 0;
    const turnaround = Number(days_required) || 5;

    const unitGross = Math.round(sellingPrice * resaleFraction);
    const unitCost = refurbCost;
    const unitNet = unitGross - unitCost;
    let isEligible = false;
    let ineligibilityReason = null;
    let explanation = '';

    if (grade === 'D') {
      isEligible = false;
      ineligibilityReason = 'Grade D damage exceeds economic refurbishment viability.';
      explanation = 'Severe damage / scrap grade makes refurbishment uneconomic.';
    } else if (demand === 0) {
      isEligible = false;
      ineligibilityReason = 'Product has zero sales demand; refurbished unit risks remaining unsold.';
      explanation = 'Zero demand velocity in catalog.';
    } else if (unitNet <= 0) {
      isEligible = false;
      ineligibilityReason = `Refurbishment cost (₹${unitCost}) exceeds resale yield (₹${unitGross}).`;
      explanation = 'Negative net recovery margin.';
    } else {
      isEligible = true;
      explanation = `Resale at ${(resaleFraction * 100).toFixed(0)}% of new (₹${unitGross}) yielding ₹${unitNet} net margin after ₹${unitCost} refurb cost.`;
    }

    const eligibleUnits = isEligible ? returned_units : 0;
    options.push({
      route: 'refurbish_and_resell',
      is_eligible: isEligible,
      ineligibility_reason: ineligibilityReason,
      recovery_channel_type: 'cash',
      eligible_units: eligibleUnits,
      unit_gross_recovery_inr: unitGross,
      unit_cost_inr: unitCost,
      unit_net_recovery_inr: unitNet,
      potential_total_net_inr: isEligible ? eligibleUnits * unitNet : 0,
      estimated_days_to_realize: turnaround,
      explanation,
      data_source: dataSource
    });
  }

  // 4. Liquidation
  {
    const liqFraction = Number(liq_pct) || 0.20;
    const unitGross = Math.round(costPrice * liqFraction);
    const unitCost = 0;
    const unitNet = unitGross;
    const isEligible = true;
    const eligibleUnits = returned_units;
    const explanation = `Instant B2B liquidation recovery at ${(liqFraction * 100).toFixed(0)}% of cost price (₹${unitGross}/unit).`;

    options.push({
      route: 'liquidation',
      is_eligible: isEligible,
      ineligibility_reason: null,
      recovery_channel_type: 'cash',
      eligible_units: eligibleUnits,
      unit_gross_recovery_inr: unitGross,
      unit_cost_inr: unitCost,
      unit_net_recovery_inr: unitNet,
      potential_total_net_inr: eligibleUnits * unitNet,
      estimated_days_to_realize: 3,
      explanation,
      data_source: dataSource
    });
  }

  return options;
}

/**
 * Evaluates return from local in-memory dataset fallback.
 */
export function evaluateReturn(returnItem) {
  initDataset();
  if (!returnItem) return [];

  const sku = returnItem.sku || returnItem.product_sku;
  const product = productsMap.get(sku) || {
    cost_price: Number(returnItem.cost_price || 1000),
    selling_price: Number(returnItem.selling_price || 1500),
    category: returnItem.category || 'Audio'
  };
  const inventory = inventoryMap.get(sku) || { new_stock: 0, avg_daily_demand: 1.0 };
  const vendorTerm = vendorTermsMap.get(sku) || { rtv_allowed: false, credit_pct: 0, window_days: 0 };
  const refurb = refurbMap.get(product.category) || { refurb_cost: 300, days_required: 5, resale_pct_of_new: 0.75 };
  const grade = (returnItem.condition_grade || returnItem.item_grade || 'B').replace(/^Grade\s*/i, '').toUpperCase();
  const liqPct = liquidationMap.get(`${product.category}_${grade}`) ?? 0.20;

  return calculateRecoveryRoutes({
    sku,
    condition_grade: grade,
    date_received: returnItem.date_received || returnItem.return_date,
    cost_price: product.cost_price,
    selling_price: product.selling_price,
    category: product.category,
    new_stock: inventory.new_stock,
    avg_daily_demand: inventory.avg_daily_demand,
    rtv_allowed: vendorTerm.rtv_allowed,
    credit_pct: vendorTerm.credit_pct,
    window_days: vendorTerm.window_days,
    refurb_cost: refurb.refurb_cost,
    days_required: refurb.days_required,
    resale_pct_of_new: refurb.resale_pct_of_new,
    liq_pct: liqPct,
    returned_units: Number(returnItem.returned_units || 1),
    dataSource: 'local_csv_fallback'
  });
}

/**
 * Connects to Supabase gb_* tables when available.
 * Returns { returns, dataSource, isDatabaseBacked, databaseStatus, notice }.
 */
export async function fetchLiveReturns(supabase) {
  if (!supabase || !isSupabaseConfigured()) {
    return {
      returns: getAllReturns(),
      dataSource: 'local_csv_fallback',
      isDatabaseBacked: false,
      databaseStatus: 'unconfigured',
      recordCount: getAllReturns().length,
      notice: 'Supabase credentials are not configured in environment variables. Serving local Challenge 10 dataset fallback.'
    };
  }

  let dbRows = null;
  let dbErr = null;

  try {
    // Query gb_returns joined with gb_products
    const res = await supabase
      .from('gb_returns')
      .select(`
        return_id,
        date_received,
        sku,
        supplier_batch,
        reason_code,
        condition_grade,
        status,
        gb_products (
          product,
          category,
          cost_price,
          selling_price,
          supplier
        )
      `)
      .order('date_received', { ascending: false });

    dbRows = res.data;
    dbErr = res.error;
  } catch (err) {
    dbErr = err;
  }

  if (!dbErr && Array.isArray(dbRows) && dbRows.length > 0) {
    const mapped = dbRows.map(r => ({
      id: r.return_id,
      return_id: r.return_id,
      return_tracking_id: r.return_id,
      date_received: r.date_received,
      return_date: r.date_received,
      sku: r.sku,
      product_sku: r.sku,
      product_name: r.gb_products?.product || r.sku,
      category: r.gb_products?.category || 'General',
      supplier_name: r.gb_products?.supplier || 'Unknown Supplier',
      batch_code: r.supplier_batch,
      reason_code: r.reason_code,
      return_reason: r.reason_code,
      condition_grade: r.condition_grade,
      item_grade: r.condition_grade,
      status: r.status,
      intake_status: r.status,
      returned_units: 1,
      cost_price: r.gb_products?.cost_price,
      selling_price: r.gb_products?.selling_price
    }));

    return {
      returns: mapped,
      dataSource: 'supabase_database',
      isDatabaseBacked: true,
      databaseStatus: 'connected',
      recordCount: mapped.length
    };
  }

  // Categorize specific database failure state
  let failureStatus = 'pending_migration';
  let failureNotice = 'Remote gb_returns table not yet migrated or populated in Supabase. Serving local Challenge 10 dataset fallback.';

  if (dbErr) {
    const errMsg = (dbErr.message || String(dbErr)).toLowerCase();
    const errCode = dbErr.code || '';

    if (errCode === '42P01' || errMsg.includes('does not exist') || errMsg.includes('relation') || errMsg.includes('not found')) {
      failureStatus = 'missing_tables';
      failureNotice = `Table gb_returns does not exist in database (not yet migrated): ${dbErr.message || errMsg}`;
    } else if (errCode === '42501' || errMsg.includes('permission denied') || errMsg.includes('row-level security') || errMsg.includes('rls')) {
      failureStatus = 'permission_denied';
      failureNotice = `Permission denied accessing gb_returns: ${dbErr.message || errMsg}`;
    } else {
      failureStatus = 'query_error';
      failureNotice = `Database query error on gb_returns: ${dbErr.message || errMsg}`;
    }
  } else if (Array.isArray(dbRows) && dbRows.length === 0) {
    failureStatus = 'table_empty';
    failureNotice = 'Table gb_returns exists but contains zero records. Serving local Challenge 10 dataset fallback.';
  }

  return {
    returns: getAllReturns(),
    dataSource: 'local_csv_fallback',
    isDatabaseBacked: false,
    databaseStatus: failureStatus,
    recordCount: getAllReturns().length,
    notice: failureNotice
  };
}

/**
 * Evaluates recovery by querying live Supabase gb_* tables first,
 * with explicit fallback to dataset when tables are pending migration.
 */
export async function evaluateLiveReturn(supabase, returnId) {
  if (supabase && isSupabaseConfigured()) {
    try {
      const { data: retRow, error: retErr } = await supabase
        .from('gb_returns')
        .select('*')
        .eq('return_id', returnId)
        .single();

      if (!retErr && retRow) {
        const [pRes, iRes, vRes, rfRes, lqRes] = await Promise.all([
          supabase.from('gb_products').select('*').eq('sku', retRow.sku).single(),
          supabase.from('gb_inventory').select('*').eq('sku', retRow.sku).single(),
          supabase.from('gb_vendor_terms').select('*').eq('sku', retRow.sku).single(),
          supabase.from('gb_refurbishment').select('*'),
          supabase.from('gb_liquidation').select('*')
        ]);

        const prod = pRes.data || {};
        const inv = iRes.data || { new_stock: 0, avg_daily_demand: 0 };
        const vTerm = vRes.data || { rtv_allowed: false, credit_pct: 0, window_days: 0 };
        const refurbList = rfRes.data || [];
        const liqList = lqRes.data || [];

        const category = prod.category || 'Audio';
        const rf = refurbList.find(r => r.category === category) || { refurb_cost: 300, days_required: 5, resale_pct_of_new: 0.75 };
        const lq = liqList.find(l => l.category === category && l.condition_grade === retRow.condition_grade);

        const routes = calculateRecoveryRoutes({
          sku: retRow.sku,
          condition_grade: retRow.condition_grade,
          date_received: retRow.date_received,
          cost_price: prod.cost_price,
          selling_price: prod.selling_price,
          category,
          new_stock: inv.new_stock,
          avg_daily_demand: inv.avg_daily_demand,
          rtv_allowed: vTerm.rtv_allowed,
          credit_pct: vTerm.credit_pct,
          window_days: vTerm.window_days,
          refurb_cost: rf.refurb_cost,
          days_required: rf.days_required,
          resale_pct_of_new: rf.resale_pct_of_new,
          liq_pct: lq ? lq.recovery_pct_of_cost : 0.20,
          returned_units: 1,
          dataSource: 'supabase_database'
        });

        return {
          routes,
          dataSource: 'supabase_database',
          isDatabaseBacked: true
        };
      }
    } catch (err) {
      // Fall through to fallback
    }
  }

  const fallbackItem = getReturnById(returnId);
  if (fallbackItem) {
    const routes = evaluateReturn(fallbackItem);
    return {
      routes,
      dataSource: 'local_csv_fallback',
      isDatabaseBacked: false,
      notice: 'Evaluated using local Challenge 10 dataset fallback (remote gb_* tables not yet migrated).'
    };
  }

  return null;
}

/**
 * Calculates high-level pipeline analytics across returns.
 */
export function getPipelineAnalytics() {
  initDataset();
  let totalReturns = allReturnsList.length;
  let totalReturnedUnits = totalReturns;
  let totalPotentialNetInr = 0;
  let cashRecoveryInr = 0;
  let creditRecoveryInr = 0;
  let openDecisions = 0;

  allReturnsList.forEach(ret => {
    if (ret.status === 'Awaiting decision') openDecisions++;
    const evals = evaluateReturn(ret);
    const eligibleRoutes = evals.filter(e => e.is_eligible);
    if (eligibleRoutes.length > 0) {
      eligibleRoutes.sort((a, b) => b.unit_net_recovery_inr - a.unit_net_recovery_inr);
      const best = eligibleRoutes[0];
      totalPotentialNetInr += best.potential_total_net_inr;
      if (best.recovery_channel_type === 'cash') {
        cashRecoveryInr += best.potential_total_net_inr;
      } else {
        creditRecoveryInr += best.potential_total_net_inr;
      }
    }
  });

  return {
    pipeline_summary: {
      total_returned_units: totalReturnedUnits,
      total_return_records: totalReturns,
      awaiting_decision_units: openDecisions,
      potential_recovery_inr: totalPotentialNetInr,
      net_cash_recovery_inr: cashRecoveryInr,
      net_supplier_credit_inr: creditRecoveryInr,
      active_skus_impacted: productsMap.size,
      snapshot_date: SNAPSHOT_DATE_STR
    },
    metrics: {
      potential_recovery_inr: totalPotentialNetInr,
      open_alerts: 5,
      recovery_plans: allReturnsList.filter(r => r.status === 'Processed').length
    }
  };
}

/**
 * Derives supplier quality and defect rate insights from returns reason codes.
 */
export function getSupplierQualityAnalytics() {
  initDataset();
  const supplierStats = new Map();

  allReturnsList.forEach(r => {
    const sName = r.supplier_name;
    if (!supplierStats.has(sName)) {
      supplierStats.set(sName, {
        supplier_name: sName,
        total_returns: 0,
        defects: 0,
        transit_damage: 0,
        customer_remorse: 0,
        batches: new Set(),
        skus: new Set()
      });
    }
    const stat = supplierStats.get(sName);
    stat.total_returns++;
    stat.batches.add(r.batch_code);
    stat.skus.add(r.sku);

    const reason = r.reason_code.toLowerCase();
    if (reason.includes('defective') || reason.includes('performance') || reason.includes('missing')) {
      stat.defects++;
    } else if (reason.includes('damaged in transit')) {
      stat.transit_damage++;
    } else {
      stat.customer_remorse++;
    }
  });

  const alerts = [];
  supplierStats.forEach((v, k) => {
    const defectRatePct = Math.round((v.defects / v.total_returns) * 100);
    if (defectRatePct >= 50 && v.total_returns >= 20) {
      alerts.push({
        id: `alert-${k.replace(/\s+/g, '-').toLowerCase()}`,
        supplier_name: k,
        severity: defectRatePct >= 65 ? 'critical' : 'high',
        defect_rate_pct: defectRatePct,
        alert_trigger_reason: `High confirmed defect rate (${defectRatePct}% of ${v.total_returns} returns flagged with technical or quality defects)`,
        status: 'open'
      });
    }
  });

  return alerts;
}
