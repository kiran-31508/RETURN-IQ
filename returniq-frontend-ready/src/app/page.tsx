"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import {
  Activity, AlertTriangle, Boxes, CheckCircle2, ChevronDown, ChevronLeft, ChevronRight,
  CircleDollarSign, ClipboardList, Database, Download, Eye, FilePlus2, Filter, HeartPulse,
  Layers3, LoaderCircle, PackageSearch, Plus, RefreshCw, Search, ShieldCheck, Sparkles,
  Truck, Wrench, X, XCircle, CalendarDays, Info, Clock, Receipt, Coins, Calculator,
} from "lucide-react";

const API_BASE = (process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:5000").replace(/\/$/, "");
type Row = Record<string, any>;
type ProductOption = { id: string; name: string; sku?: string | null; supplier_id?: string | null; supplier_name?: string | null };
type BatchOption = { id: string; batch_code: string; product_id: string; supplier_id?: string | null; supplier_name?: string | null; vendor_return_deadline?: string | null };
type RouteOption = Row;
type ToastState = { kind: "success" | "error" | "info"; message: string } | null;
type IntakeForm = { return_tracking_id: string; product_id: string; batch_id: string; returned_units: string; item_grade: string; return_date: string; return_reason: string; is_confirmed_defect: boolean; vendor_eligible_units: string; notes: string };

const pick = (o: Row | null | undefined, keys: string[], fallback: any = undefined) => {
  for (const key of keys) if (o?.[key] !== undefined && o?.[key] !== null) return o[key];
  return fallback;
};
const arr = (p: any): Row[] => {
  if (Array.isArray(p)) return p;
  if (Array.isArray(p?.returns)) return p.returns;
  if (Array.isArray(p?.options)) return p.options;
  if (Array.isArray(p?.routes)) return p.routes;
  if (Array.isArray(p?.results)) return p.results;
  if (Array.isArray(p?.data)) return p.data;
  if (Array.isArray(p?.data?.returns)) return p.data.returns;
  if (Array.isArray(p?.data?.routes)) return p.data.routes;
  return [];
};
const fmt = (v: any) => v == null || v === "" || !Number.isFinite(Number(v)) ? "—" : new Intl.NumberFormat("en-IN", { maximumFractionDigits: 1 }).format(Number(v));
const money = (v: any) => v == null || v === "" || !Number.isFinite(Number(v)) ? "—" : new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(Number(v));
const pretty = (v: any) => String(v ?? "Unknown").replaceAll("_", " ").replace(/\b\w/g, c => c.toUpperCase());
const rowGrade = (r: Row) => pick(r, ["item_grade", "condition_grade", "grade", "condition"], "Unknown");
const rowTracking = (r: Row) => pick(r, ["return_tracking_id", "tracking_id"], pick(r, ["id", "return_id"], "—"));
const rowProduct = (r: Row) => pick(r, ["product_name", "product", "product_sku", "sku"], pick(r?.products, ["name", "sku"], "Product details unavailable"));
const rowSupplier = (r: Row) => pick(r, ["supplier_name", "supplier"], pick(r?.suppliers, ["name"], "—"));
const rowBatch = (r: Row) => pick(r, ["batch_code", "batch"], pick(r?.supplier_batches, ["batch_code"], "—"));
const rowStatus = (r: Row) => pick(r, ["intake_status", "status"], "received");

async function api(path: string, init?: RequestInit) {
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: { ...(init?.body ? { "Content-Type": "application/json" } : {}), ...init?.headers },
    cache: "no-store",
  });
  const raw = await response.text();
  let data: any = null;
  try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
  if (!response.ok) {
    const detail = Array.isArray(data?.validation_errors) ? data.validation_errors.join(" ") : data?.details;
    throw new Error(`${detail || data?.message || data?.error || `HTTP ${response.status}`} (HTTP ${response.status})`);
  }
  return data;
}

function Metric({ icon, label, value, hint, tone }: { icon: ReactNode; label: string; value: React.ReactNode; hint: string; tone: string }) {
  return <article className="metric"><div className={`metric-icon ${tone}`}>{icon}</div><div className="metric-label">{label}</div><div className="metric-value">{value}</div><div className="metric-hint">{hint}</div></article>;
}

function exportCsv(rows: Row[]) {
  const columns: [string, (r: Row) => any][] = [
    ["return_tracking_id", r => rowTracking(r)], ["product_name", r => rowProduct(r)], ["product_sku", r => pick(r, ["product_sku", "sku"], "")],
    ["supplier_name", r => rowSupplier(r)], ["batch_code", r => rowBatch(r)], ["item_grade", r => rowGrade(r)],
    ["returned_units", r => pick(r, ["returned_units", "units_returned"], "")], ["intake_status", r => rowStatus(r)], ["id", r => pick(r, ["id", "return_id"], "")],
  ];
  const escape = (v: any) => `"${String(v ?? "").replaceAll('"', '""')}"`;
  const csv = [columns.map(([key]) => key).join(","), ...rows.map(r => columns.map(([, get]) => escape(get(r))).join(","))].join("\r\n");
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8;" }));
  const a = document.createElement("a"); a.href = url; a.download = "returniq-inventory.csv"; a.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

const gradeChoices = ["Grade A", "Grade B", "Grade C", "Grade D"];
const statusChoices = ["received", "inspected", "allocated", "completed"];

export default function Home() {
  const [returns, setReturns] = useState<Row[]>([]);
  const [analytics, setAnalytics] = useState<Row | null>(null);
  const [alerts, setAlerts] = useState<Row[]>([]);
  const [selectedId, setSelectedId] = useState("");
  const [routes, setRoutes] = useState<RouteOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [evaluating, setEvaluating] = useState(false);
  const [error, setError] = useState("");
  const [routeError, setRouteError] = useState("");
  const [online, setOnline] = useState<"checking" | "online" | "offline">("checking");
  const [healthText, setHealthText] = useState("Checking API health…");
  const [updated, setUpdated] = useState("");
  const [section, setSection] = useState("Overview");
  const [search, setSearch] = useState("");
  const [gradeFilter, setGradeFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState("10");
  const [alertSearch, setAlertSearch] = useState("");
  const [alertSeverity, setAlertSeverity] = useState("all");

  const [intakeOpen, setIntakeOpen] = useState(false);
  const [optionsLoading, setOptionsLoading] = useState(false);
  const [optionsError, setOptionsError] = useState("");
  const [products, setProducts] = useState<ProductOption[]>([]);
  const [batches, setBatches] = useState<BatchOption[]>([]);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState("");
  const [toast, setToast] = useState<ToastState>(null);
  const [detailOpen, setDetailOpen] = useState(false);
  const [details, setDetails] = useState<Row | null>(null);

  const [form, setForm] = useState<IntakeForm>({
    return_tracking_id: "", product_id: "", batch_id: "", returned_units: "1", item_grade: "Grade B",
    return_date: "", return_reason: "", is_confirmed_defect: false, vendor_eligible_units: "0", notes: "",
  });

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(null), 4500);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const refresh = useCallback(async (preferredId?: string) => {
    setLoading(true); setError("");
    const health = await api("/api/health").then(() => ({ ok: true as const, error: "" })).catch((e: any) => ({ ok: false as const, error: e?.message || "Health endpoint unavailable" }));
    setOnline(health.ok ? "online" : "offline"); setHealthText(health.ok ? "Health endpoint responded" : health.error);
    try {
      const results = await Promise.allSettled([api("/api/returns"), api("/api/analytics/pipeline")]);
      if (results[0].status === "rejected") throw results[0].reason;
      const payload = results[0].value;
      const rows = arr(payload);
      setReturns(rows);
      setAlerts(Array.isArray(payload?.open_alerts) ? payload.open_alerts : Array.isArray(payload?.alerts) ? payload.alerts : Array.isArray(payload?.data?.open_alerts) ? payload.data.open_alerts : Array.isArray(payload?.data?.alerts) ? payload.data.alerts : []);
      setAnalytics(results[1].status === "fulfilled" ? results[1].value : null);
      setUpdated(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }));
      const desired = preferredId || selectedId;
      setSelectedId(desired && rows.some(r => String(pick(r, ["id", "return_id"])) === desired) ? desired : String(pick(rows[0], ["id", "return_id"], "")));
      if (results[1].status === "rejected") setAnalytics(null);
    } catch (e: any) {
      setError(e?.message || "Unable to load live backend data.");
    } finally { setLoading(false); }
  }, [selectedId]);

  useEffect(() => { void refresh(); /* Initial load only; refresh remains callable from actions. */ // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selected = useMemo(() => returns.find(r => String(pick(r, ["id", "return_id"])) === selectedId), [returns, selectedId]);
  const filteredReturns = useMemo(() => returns.filter(r => {
    const term = search.trim().toLowerCase();
    const fields = [rowTracking(r), rowProduct(r), pick(r, ["product_sku", "sku"], ""), rowBatch(r), rowSupplier(r)].join(" ").toLowerCase();
    const grade = String(rowGrade(r)).toLowerCase();
    const status = String(rowStatus(r)).toLowerCase();
    return (!term || fields.includes(term)) && (gradeFilter === "all" || grade.includes(gradeFilter.toLowerCase())) && (statusFilter === "all" || status === statusFilter);
  }), [returns, search, gradeFilter, statusFilter]);
  const rowsPerPage = Number(pageSize);
  const pageCount = Math.max(1, Math.ceil(filteredReturns.length / rowsPerPage));
  const currentPage = Math.min(page, pageCount);
  const pagedReturns = filteredReturns.slice((currentPage - 1) * rowsPerPage, currentPage * rowsPerPage);
  useEffect(() => { setPage(1); }, [search, gradeFilter, statusFilter, pageSize]);

  const filteredAlerts = useMemo(() => alerts.filter(a => {
    const term = alertSearch.trim().toLowerCase();
    const text = [pick(a, ["supplier_name", "supplier"], ""), pick(a, ["product_name"], ""), pick(a, ["batch_code"], ""), pick(a, ["alert_trigger_reason", "message"], ""), pick(a, ["severity", "alert_level"], "")].join(" ").toLowerCase();
    const sev = String(pick(a, ["severity", "alert_level"], "unknown")).toLowerCase();
    return (!term || text.includes(term)) && (alertSeverity === "all" || sev === alertSeverity);
  }), [alerts, alertSearch, alertSeverity]);

  const evaluate = async () => {
    if (!selectedId) { setRouteError("Select a returned inventory record first."); return; }
    setEvaluating(true); setRouteError(""); setRoutes([]);
    try {
      const result = await api("/api/routes/evaluate", { method: "POST", body: JSON.stringify({ return_id: selectedId }) });
      const options = arr(result);
      if (!options.length) throw new Error("The API responded, but no recovery options were found in its response. Check the evaluate route response shape.");
      setRoutes(options);
    } catch (e: any) { setRouteError(e?.message || "Recovery evaluation failed."); }
    finally { setEvaluating(false); }
  };

  const loadOptions = async () => {
    setOptionsLoading(true); setOptionsError("");
    try {
      const result = await api("/api/returns/options");
      const nextProducts = Array.isArray(result?.products) ? result.products : [];
      const nextBatches = Array.isArray(result?.batches) ? result.batches : [];
      setProducts(nextProducts); setBatches(nextBatches);
      setForm(old => ({ ...old, product_id: nextProducts.some((p: ProductOption) => p.id === old.product_id) ? old.product_id : "", batch_id: nextBatches.some((b: BatchOption) => b.id === old.batch_id) ? old.batch_id : "" }));
      if (!nextProducts.length) setOptionsError("No products were returned by the backend. Add or verify products and supplier batches in your database first.");
    } catch (e: any) {
      setOptionsError(e?.message || "Could not load product and batch options. Confirm the intake endpoints are integrated into the backend.");
    } finally { setOptionsLoading(false); }
  };

  const openIntake = () => {
    setFormError(""); setOptionsError(""); setIntakeOpen(true);
    void loadOptions();
  };

  const filteredBatches = useMemo(() => batches.filter(b => b.product_id === form.product_id), [batches, form.product_id]);
  const updateForm = <K extends keyof IntakeForm,>(key: K, value: IntakeForm[K]) => setForm(old => ({ ...old, [key]: value }));

  const submitIntake = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setFormError("");
    const units = Number(form.returned_units);
    const vendorUnits = Number(form.vendor_eligible_units);
    if (!form.return_tracking_id.trim() || !form.product_id || !form.batch_id || !form.return_reason.trim()) {
      setFormError("Complete the tracking ID, product, batch, quantity, grade, and return reason before saving."); return;
    }
    if (!Number.isInteger(units) || units <= 0) { setFormError("Returned units must be a positive whole number."); return; }
    if (!Number.isInteger(vendorUnits) || vendorUnits < 0 || vendorUnits > units) { setFormError("Vendor-eligible units must be a whole number between 0 and the returned quantity."); return; }
    const product = products.find(p => p.id === form.product_id);
    const batch = batches.find(b => b.id === form.batch_id);
    if (!product || !batch || batch.product_id !== product.id) { setFormError("Choose a valid batch that belongs to the selected product."); return; }

    const payload: Row = {
      return_tracking_id: form.return_tracking_id.trim(),
      product_id: form.product_id,
      batch_id: form.batch_id,
      returned_units: units,
      item_grade: form.item_grade,
      return_reason: form.return_reason.trim(),
      is_confirmed_defect: form.is_confirmed_defect,
      vendor_eligible_units: vendorUnits,
    };
    if (form.return_date) payload.return_date = form.return_date;
    if (form.notes.trim()) payload.notes = form.notes.trim();

    setSaving(true);
    try {
      const response = await api("/api/returns", { method: "POST", body: JSON.stringify(payload) });
      const saved = response?.return;
      if (!saved?.id || !saved?.return_tracking_id) throw new Error("The API did not return the saved record in the documented { return: ... } format. Confirm the backend response contract; no success is assumed.");
      setIntakeOpen(false);
      setToast({ kind: "success", message: `Return ${saved.return_tracking_id} was saved successfully.` });
      setSection("Returns inventory");
      setSearch(""); setGradeFilter("all"); setStatusFilter("all");
      setForm({ return_tracking_id: "", product_id: "", batch_id: "", returned_units: "1", item_grade: "Grade B", return_date: "", return_reason: "", is_confirmed_defect: false, vendor_eligible_units: "0", notes: "" });
      await refresh(String(saved.id));
    } catch (e: any) {
      setFormError(e?.message || "The return could not be saved. Your entered values have been preserved.");
    } finally { setSaving(false); }
  };

  const metrics = analytics?.metrics || analytics?.data || analytics || {};
  const returnedUnits = returns.reduce((n, r) => n + (Number(pick(r, ["returned_units", "units_returned"], 0)) || 0), 0);
  const potential = pick(metrics, ["potential_recovery_inr", "total_potential_recovery_inr", "pipeline_value_inr", "potential_recovery"]);
  const alertCount = pick(metrics, ["open_alerts", "open_alert_count", "active_alerts"], alerts.length);
  const planCount = pick(metrics, ["recovery_plans", "recovery_plan_count", "plans_count"]);
  const routeName = (r: Row) => String(pick(r, ["route", "route_name", "recovery_route", "strategy"], "Unknown route"));
  const getRouteFormula = (name: string, gross: number, cost: number, net: number) => {
    const s = name.toLowerCase();
    if (s.includes("restock")) {
      return {
        tag: "100% MSP Direct Resale",
        equation: "Selling Price − Shelving Cost (₹0) = Net Margin",
        breakdown: "Direct shelf replenishment of Grade A inventory. Restores 100% catalog retail value without refurbishment cost.",
        grossType: "Full Catalog MSP",
        costType: "Shelving / QC",
      };
    }
    if (s.includes("vendor") || s.includes("rtv")) {
      return {
        tag: "Supplier Credit Terms",
        equation: "Wholesale Cost Price × Contract Credit % = Vendor Credit",
        breakdown: "Contractual vendor allowance credited directly to supplier ledger account. Offset against future POs (Non-Cash).",
        grossType: "Contract RMA Credit",
        costType: "Supplier Absorbed",
      };
    }
    if (s.includes("refurb")) {
      return {
        tag: "Refurbished Resale Yield",
        equation: "Secondary Resale Yield − Refurb Parts & Labor = Net Margin",
        breakdown: "Secondary market resale yield after deducting category technician labor, component repair, and packaging costs.",
        grossType: "Secondary Resale Yield",
        costType: "Direct Refurb Cost",
      };
    }
    return {
      tag: "B2B Liquidation Floor",
      equation: "Wholesale Cost Price × Clearance Recovery % = Net Cash Payout",
      breakdown: "Floor recovery via instant as-is wholesale auction buyer bids. Zero repair overhead or RMA processing delay.",
      grossType: "Clearance Bid Yield",
      costType: "As-Is Lot Handling",
    };
  };
  const routeIcon = (s: string) => s.toLowerCase().includes("vendor") ? <Truck size={17} /> : s.toLowerCase().includes("refurb") ? <Wrench size={17} /> : s.toLowerCase().includes("liquid") ? <CircleDollarSign size={17} /> : <Boxes size={17} />;
  const navItems: [string, any][] = [["Overview", Activity], ["Returns inventory", PackageSearch], ["Recovery planning", Sparkles], ["Supplier quality", ShieldCheck]];
  const openDetails = (record: Row) => { setDetails(record); setDetailOpen(true); };

  return <main className="shell">
    <aside className="sidebar">
      <div className="brand"><div className="brand-mark"><Layers3 size={21} /></div><div><div className="brand-name">Return<span>IQ</span></div><div className="brand-caption">RECOVERY INTELLIGENCE</div></div></div>
      <div className="nav-label">WORKSPACE</div>
      <nav>{navItems.map(([label, Icon]) => <button key={label} className={`nav-item ${section === label ? "active" : ""}`} onClick={() => setSection(label)}><Icon size={18} /><span>{label}</span>{label === "Supplier quality" && alerts.length > 0 && <b>{alerts.length}</b>}</button>)}</nav>
      <div className="sidebar-bottom">
        <div className="connection"><div><i className={`dot ${online}`} /><strong>Backend connection</strong></div><p>{online === "online" ? "Express API reachable" : online === "checking" ? "Checking connection…" : "API unavailable"}</p><small>{API_BASE}</small><button className="health-button" onClick={() => void refresh()} disabled={loading}><HeartPulse size={13} /> Test & refresh</button></div>
        <div className="workspace-user"><div className="avatar">RI</div><div><strong>ReturnIQ Workspace</strong><small>Operations team</small></div><ChevronDown size={15} /></div>
      </div>
    </aside>

    <section className="main">
      <header className="topbar"><div className="crumb">Workspace <span>/</span> <strong>{section}</strong></div><div className="top-actions"><span className={`api-status ${online}`}><i className="dot" /> {online === "online" ? "API connected" : online === "checking" ? "Connecting" : "API offline"}</span><button className="icon-button" onClick={() => void refresh()} disabled={loading} aria-label="Refresh live backend data" title="Refresh live backend data"><RefreshCw size={16} className={loading ? "spin" : ""} /></button><div className="avatar">RI</div></div></header>
      <div className="content">
        <div className="page-heading"><div><div className="eyebrow">REVERSE LOGISTICS · CONTROL TOWER</div><h1>{section === "Overview" ? "Returns Command Center" : section}</h1><p>{section === "Recovery planning" ? "Compare recovery pathways using the backend decision engine." : section === "Supplier quality" ? "Review supplier quality alerts returned by the backend." : section === "Returns inventory" ? "Search, inspect, and add returned inventory from your live database." : "Recover value from returned inventory. Keep supplier quality in view."}</p></div><div className="heading-meta"><span className="live"><i className="dot online" /> LIVE DATA</span><small>{updated ? `Updated ${updated}` : "Waiting for API data"}</small></div></div>

        {error && <div className="error-banner"><AlertTriangle size={18} /><div><strong>Couldn't load live returns</strong><p>{error}</p><small>API health: {healthText}. Check that Express is running and the frontend API URL is correct. No mock data is substituted.</small></div><button onClick={() => void refresh()} disabled={loading}>Retry</button></div>}
        {toast && <div className={`toast toast-${toast.kind}`} role="status" aria-live="polite"><span className="toast-icon">{toast.kind === "success" ? <CheckCircle2 size={17} /> : toast.kind === "error" ? <AlertTriangle size={17} /> : <Info size={17} />}</span><span>{toast.message}</span><button onClick={() => setToast(null)} aria-label="Dismiss notification"><X size={15} /></button></div>}

        {section === "Overview" && <>
          <div className="metrics">
            <Metric icon={<PackageSearch size={19} />} label="Returned units" value={loading ? "…" : fmt(returnedUnits)} hint={`${returns.length} return records loaded`} tone="blue" />
            <Metric icon={<CircleDollarSign size={19} />} label="Potential recovery" value={potential == null ? "—" : money(potential)} hint={potential == null ? "Not provided by analytics API" : "Live pipeline analytics"} tone="green" />
            <Metric icon={<AlertTriangle size={19} />} label="Open quality alerts" value={loading ? "…" : fmt(alertCount)} hint={`${alerts.length} alert records returned`} tone="amber" />
            <Metric icon={<Layers3 size={19} />} label="Recovery plans" value={planCount == null ? "—" : fmt(planCount)} hint={planCount == null ? "Not provided by analytics API" : "Live pipeline analytics"} tone="violet" />
          </div>
          <div className="overview-actions"><button className="primary" onClick={openIntake}><Plus size={15} /> Add Return</button><button className="secondary" onClick={() => setSection("Returns inventory")}><PackageSearch size={15} /> Browse inventory</button><button className="secondary" onClick={() => setSection("Recovery planning")}><Sparkles size={15} /> Compare recovery routes</button><button className="secondary" onClick={() => setSection("Supplier quality")}><ShieldCheck size={15} /> Review quality alerts</button><button className="secondary" onClick={() => exportCsv(returns)} disabled={!returns.length}><Download size={15} /> Export inventory CSV</button></div>
        </>}

        {(section === "Overview" || section === "Returns inventory") && <section className="panel inventory">
          <div className="panel-head inventory-head"><div><div className="kicker">INVENTORY INTAKE</div><h2>Returned inventory</h2></div><div className="table-tools"><label className="search-box"><Search size={15} /><input aria-label="Search inventory" placeholder="Search return, SKU, supplier…" value={search} onChange={e => setSearch(e.target.value)} /></label><label className="filter-box"><Filter size={14} /><select aria-label="Filter by condition" value={gradeFilter} onChange={e => setGradeFilter(e.target.value)}><option value="all">All grades</option>{gradeChoices.map(g => <option key={g} value={g.toLowerCase()}>{g}</option>)}</select></label><label className="filter-box"><ClipboardList size={14} /><select aria-label="Filter by intake status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)}><option value="all">All statuses</option>{statusChoices.map(s => <option key={s} value={s}>{pretty(s)}</option>)}</select></label><button className="secondary compact" onClick={() => exportCsv(filteredReturns)} disabled={!filteredReturns.length}><Download size={14} /> CSV</button></div><button className="primary add-return-inline" onClick={openIntake}><Plus size={14} /> Add Return</button><span className="tag">{filteredReturns.length} / {returns.length} records</span></div>
          <div className="table-scroll"><table><thead><tr><th>Return / product</th><th>Supplier / batch</th><th>Condition</th><th>Units</th><th>Status</th><th>Actions</th></tr></thead><tbody>
            {loading ? <tr><td colSpan={6} className="empty">Loading live records…</td></tr> : pagedReturns.length === 0 ? <tr><td colSpan={6} className="empty"><PackageSearch size={19} /><br />No matching return records in backend.</td></tr> : pagedReturns.map((r, i) => { const id = String(pick(r, ["id", "return_id"], `row-${i}`)); const condition = rowGrade(r); const gradeClass = String(condition).toLowerCase().includes("a") ? "grade-a" : String(condition).toLowerCase().includes("b") ? "grade-b" : "grade-c"; return <tr key={id} onClick={() => { setSelectedId(id); setRoutes([]); setRouteError(""); }} className={selectedId === id ? "selected" : ""}><td><strong>{rowTracking(r)}</strong><small>{rowProduct(r)}</small></td><td><strong>{rowSupplier(r)}</strong><small>{rowBatch(r)}</small></td><td><span className={`grade ${gradeClass}`}>{pretty(condition)}</span></td><td>{fmt(pick(r, ["returned_units", "units_returned"], 0))}</td><td><span className="status-dot-text"><i className={`dot ${String(rowStatus(r)).toLowerCase() === "completed" ? "online" : "checking"}`} />{pretty(rowStatus(r))}</span></td><td><div className="row-actions"><button className="table-action" onClick={e => { e.stopPropagation(); openDetails(r); }} aria-label={`View details for ${rowTracking(r)}`}><Eye size={13} /> Details</button><button className="table-action" onClick={e => { e.stopPropagation(); setSelectedId(id); setRoutes([]); setRouteError(""); setSection("Recovery planning"); }}>Evaluate <Sparkles size={13} /></button></div></td></tr>; })}
          </tbody></table></div>
          <div className="panel-foot"><span>Selected: {selected ? rowTracking(selected) : "No return selected"}</span><div className="pagination"><label>Rows <select aria-label="Rows per page" value={pageSize} onChange={e => setPageSize(e.target.value)}><option value="10">10</option><option value="25">25</option><option value="50">50</option></select></label><button className="page-button" onClick={() => setPage(p => Math.max(1, p - 1))} disabled={currentPage <= 1} aria-label="Previous page"><ChevronLeft size={15} /></button><span>Page {currentPage} of {pageCount}</span><button className="page-button" onClick={() => setPage(p => Math.min(pageCount, p + 1))} disabled={currentPage >= pageCount} aria-label="Next page"><ChevronRight size={15} /></button><button className="link-button" onClick={() => void refresh()} disabled={loading}>Refresh ↗</button></div></div>
        </section>}

        {(section === "Overview" || section === "Supplier quality") && <section className="panel quality quality-section"><div className="panel-head inventory-head"><div><div className="kicker">SUPPLIER RISK</div><h2>Quality watch</h2></div>{section === "Supplier quality" && <div className="table-tools"><label className="search-box"><Search size={15} /><input aria-label="Search supplier alerts" placeholder="Search supplier, batch…" value={alertSearch} onChange={e => setAlertSearch(e.target.value)} /></label><label className="filter-box"><Filter size={14} /><select aria-label="Filter alerts by severity" value={alertSeverity} onChange={e => setAlertSeverity(e.target.value)}><option value="all">All severity</option><option value="critical">Critical</option><option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option></select></label></div>}<span className={`tag ${alerts.length ? "tag-warn" : ""}`}>{filteredAlerts.length} shown · {alerts.length} open</span></div>{filteredAlerts.length ? <div className="alert-list">{filteredAlerts.map((a, i) => { const severity = String(pick(a, ["severity", "alert_level"], "open")).toLowerCase(); return <div className="alert-row" key={a.id || i}><div className="alert-icon"><AlertTriangle size={16} /></div><div className="alert-copy"><strong>{pick(a, ["supplier_name", "supplier", "batch_code"], "Supplier quality alert")}</strong><span>{pick(a, ["product_name", "alert_trigger_reason", "message"], "Review supplier batch quality")}</span><small>{pick(a, ["defect_rate_pct", "defect_rate"], null) != null ? `${pick(a, ["defect_rate_pct", "defect_rate"])}% defect rate` : pretty(severity)}</small></div><span className={`severity ${severity}`}>{pretty(severity)}</span></div>; })}</div> : <div className="quality-empty"><div className="check-icon"><ShieldCheck size={22} /></div><strong>{alerts.length ? "No alerts match these filters" : "No alert records returned"}</strong><span>{alerts.length ? "Try adjusting the search or severity filter." : "The API returned no alert rows; this does not prove every supplier is defect-free."}</span></div>}<div className="panel-foot"><span>Alert information comes from the live backend response.</span></div></section>}

        {(section === "Overview" || section === "Recovery planning") && <section className="panel recovery"><div className="panel-head recovery-head"><div><div className="kicker">DECISION SUPPORT</div><h2>Recovery options</h2><p>Compare Restock, Return to Vendor, Refurbish & Resell, and Liquidation with transparent cost breakdowns and payment channels.</p></div><button className="primary" onClick={evaluate} disabled={evaluating || !selectedId}>{evaluating ? <LoaderCircle size={16} className="spin" /> : <Sparkles size={16} />} {evaluating ? "Evaluating…" : "Evaluate selected return"}</button></div>
          {routeError && <div className="inline-error"><AlertTriangle size={16} />{routeError}<button className="link-button" onClick={() => void evaluate()} disabled={evaluating}>Retry evaluation</button></div>}
          {!routes.length ? <div className="route-empty"><div className="route-empty-icon"><Activity size={21} /></div><div><strong>{selected ? `Selected: ${rowTracking(selected)}` : "Select a return to get started"}</strong><span>Evaluation calls POST /api/routes/evaluate. Results appear here only after the backend returns them; no recovery outcome is assumed.</span></div></div> : <>
            {selected && (
              <div className="evaluated-return-banner">
                <div className="evaluated-return-info">
                  <span className="eval-tag">CURRENT EVALUATION</span>
                  <strong className="eval-id">{rowTracking(selected)}</strong>
                  <span className="eval-dot">·</span>
                  <span className="eval-prod">{rowProduct(selected)}</span>
                  <span className="eval-dot">·</span>
                  <span className="eval-grade">{pretty(rowGrade(selected))}</span>
                  <span className="eval-dot">·</span>
                  <span className="eval-supp">{rowSupplier(selected)}</span>
                </div>
              </div>
            )}
            <div className="route-grid">{routes.map((r, i) => {
            const name = routeName(r);
            const eligible = pick(r, ["is_eligible", "eligible"], null);
            const eligibleUnits = Number(pick(r, ["eligible_units", "units_eligible"], 0)) || 0;
            const estimatedDays = pick(r, ["estimated_days_to_realize", "estimated_days"], null);
            const unitGross = Number(pick(r, ["unit_gross_recovery_inr", "gross_recovery_per_unit_inr"], 0)) || 0;
            const unitCost = Number(pick(r, ["unit_cost_inr", "cost_per_unit_inr"], 0)) || 0;
            const unitNet = Number(pick(r, ["unit_net_recovery_inr", "net_recovery_per_unit_inr"], 0)) || 0;
            const potentialTotalNet = Number(pick(r, ["potential_total_net_inr", "total_net_recovery_inr", "potential_recovery_inr"], 0)) || 0;
            const ineligibilityReason = pick(r, ["ineligibility_reason", "reason"], null);
            const explanation = pick(r, ["explanation", "description"], null);
            const channelType = String(pick(r, ["recovery_channel_type", "recovery_channel"], "cash")).toLowerCase();
            const isCredit = channelType.includes("credit") || channelType.includes("supplier") || channelType.includes("vendor");
            const formula = getRouteFormula(name, unitGross, unitCost, unitNet);

            return (
              <article className={`route-card ${eligible === true ? "eligible" : eligible === false ? "ineligible" : "eligibility-unknown"}`} key={`${name}-${i}`}>
                <div className="route-card-top">
                  <div className="route-icon-title">
                    <div className="route-icon">{routeIcon(name)}</div>
                    <div>
                      <h3 className="route-card-title">{pretty(name)}</h3>
                      <span className="route-formula-pill">{formula.tag}</span>
                    </div>
                  </div>
                  <span className={`eligibility ${eligible === true ? "yes" : eligible === false ? "no" : "unknown"}`}>
                    {eligible === true ? <CheckCircle2 size={13} /> : eligible === false ? <XCircle size={13} /> : <Info size={13} />}
                    {eligible === true ? "Eligible" : eligible === false ? "Not eligible" : "Eligibility unavailable"}
                  </span>
                </div>

                <div className={`route-channel-badge ${isCredit ? "channel-credit" : "channel-cash"}`}>
                  <div className="channel-badge-top">
                    {isCredit ? <Receipt size={14} className="channel-icon" /> : <Coins size={14} className="channel-icon" />}
                    <span className="channel-type-name">{isCredit ? "SUPPLIER CREDIT" : "CASH PROCEEDS"}</span>
                    <span className="channel-nature-tag">{isCredit ? "NON-CASH VENDOR BALANCE" : "DIRECT LIQUID CASH"}</span>
                  </div>
                  <div className="channel-desc">
                    {isCredit
                      ? "Vendor ledger balance — credited against future purchase invoices (non-cash)"
                      : "Direct cash inflow — liquid capital realized from sale / payout"}
                  </div>
                </div>

                <div className="route-headline-box">
                  <div className="route-total-wrap">
                    <span className="route-caption">POTENTIAL NET REALIZED RECOVERY</span>
                    <div className={`route-total ${eligible === true ? "text-success" : "text-muted"}`}>
                      {eligible === true ? money(potentialTotalNet) : "₹0"}
                    </div>
                    <div className="route-unit-net-sub">
                      {eligible === true ? (
                        <span><strong>{money(unitNet)}</strong> / unit net realized × {fmt(eligibleUnits)} units</span>
                      ) : (
                        <span className="text-warn">No net recovery realized (ineligible condition)</span>
                      )}
                    </div>
                  </div>
                </div>

                <div className="route-breakdown-section">
                  <div className="breakdown-title">
                    <span>COST & VALUE BREAKDOWN (PER UNIT)</span>
                  </div>
                  <div className="route-math-grid">
                    <div className="math-cell math-gross">
                      <span className="math-label">Expected Resale / Gross</span>
                      <strong className="math-value">{money(unitGross)}</strong>
                      <span className="math-sub">{formula.grossType}</span>
                    </div>
                    <div className="math-operator">−</div>
                    <div className="math-cell math-cost">
                      <span className="math-label">Incremental Direct Cost</span>
                      <strong className={`math-value ${unitCost > 0 ? "cost-positive" : "cost-zero"}`}>
                        {unitCost > 0 ? `− ${money(unitCost)}` : "₹0"}
                      </strong>
                      <span className="math-sub">{unitCost > 0 ? formula.costType : "No direct cost"}</span>
                    </div>
                    <div className="math-operator">=</div>
                    <div className="math-cell math-net">
                      <span className="math-label">Net Recovery Margin</span>
                      <strong className="math-value net-highlight">{money(unitNet)}</strong>
                      <span className="math-sub">Per unit net margin</span>
                    </div>
                  </div>
                </div>

                <div className="route-formula-box">
                  <div className="formula-header">
                    <Calculator size={12} />
                    <span>VALUATION FORMULA</span>
                  </div>
                  <code className="formula-equation">{formula.equation}</code>
                  <p className="formula-explanation">{formula.breakdown}</p>
                </div>

                <div className="route-meta-strip">
                  <div className="meta-strip-item">
                    <Clock size={13} />
                    <span>Realization Turnaround: <strong>{estimatedDays != null ? `${fmt(estimatedDays)} day${Number(estimatedDays) === 1 ? "" : "s"}` : "—"}</strong></span>
                  </div>
                  <div className="meta-strip-item">
                    <Boxes size={13} />
                    <span>Eligible Units: <strong>{fmt(eligibleUnits)}</strong></span>
                  </div>
                </div>

                {eligible === false && ineligibilityReason && (
                  <div className="route-ineligible-banner">
                    <XCircle size={15} />
                    <div>
                      <strong>Ineligible Condition</strong>
                      <p>{ineligibilityReason}</p>
                    </div>
                  </div>
                )}

                {explanation && (
                  <div className="route-engine-explanation">
                    <Info size={12} />
                    <span>{explanation}</span>
                  </div>
                )}
              </article>
            );
          })}</div></>}
          <div className="route-note"><ShieldCheck size={15} /><span>Estimates come from the backend decision function. Recovery-plan creation is not exposed here because its write contract must be verified separately.</span></div></section>}

        <footer className="footer"><span>ReturnIQ · Reverse logistics intelligence</span><span><Database size={13} /> Express API · Supabase-backed</span></footer>
      </div>
    </section>

    {intakeOpen && <div className="modal-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget && !saving) setIntakeOpen(false); }}><section className="intake-modal" role="dialog" aria-modal="true" aria-labelledby="intake-title"><div className="modal-header"><div className="modal-heading-icon"><FilePlus2 size={19} /></div><div className="modal-title-wrap"><div className="kicker">INVENTORY INTAKE</div><h2 id="intake-title">Add a new return</h2><p>Register returned inventory with an existing product and supplier batch.</p></div><button className="modal-close" onClick={() => !saving && setIntakeOpen(false)} disabled={saving} aria-label="Close intake form"><X size={18} /></button></div>
      <div className="modal-body">{optionsLoading && <div className="form-info"><LoaderCircle size={15} className="spin" /> Loading current products and supplier batches from your backend…</div>}{optionsError && <div className="inline-error form-message"><AlertTriangle size={15} /><span>{optionsError}</span><button className="link-button" onClick={() => void loadOptions()} disabled={optionsLoading}>Retry</button></div>}{formError && <div className="inline-error form-message" role="alert"><AlertTriangle size={15} /><span>{formError}</span></div>}
        <form id="return-intake-form" onSubmit={submitIntake}>
          <div className="form-section-title"><span>01</span><div><strong>Return details</strong><small>Identify the returned shipment</small></div></div>
          <div className="form-grid"><label className="field full"><span>Return tracking ID <b>*</b></span><input value={form.return_tracking_id} onChange={e => updateForm("return_tracking_id", e.target.value)} required maxLength={120} placeholder="e.g. RET-NEW-001" autoComplete="off" /></label>
            <label className="field"><span>Product <b>*</b></span><select value={form.product_id} onChange={e => setForm(old => ({ ...old, product_id: e.target.value, batch_id: "" }))} required disabled={optionsLoading || !products.length}><option value="">{optionsLoading ? "Loading products…" : "Select product"}</option>{products.map(p => <option key={p.id} value={p.id}>{p.name}{p.sku ? ` · ${p.sku}` : ""}{p.supplier_name ? ` · ${p.supplier_name}` : ""}</option>)}</select></label>
            <label className="field"><span>Supplier batch <b>*</b></span><select value={form.batch_id} onChange={e => updateForm("batch_id", e.target.value)} required disabled={!form.product_id || !filteredBatches.length || optionsLoading}><option value="">{!form.product_id ? "Select a product first" : optionsLoading ? "Loading batches…" : filteredBatches.length ? "Select batch" : "No batches for this product"}</option>{filteredBatches.map(b => <option key={b.id} value={b.id}>{b.batch_code}{b.supplier_name ? ` · ${b.supplier_name}` : ""}{b.vendor_return_deadline ? ` · deadline ${b.vendor_return_deadline}` : ""}</option>)}</select></label>
          </div>
          <div className="form-section-title"><span>02</span><div><strong>Inspection</strong><small>Quantity, condition, and eligibility</small></div></div>
          <div className="form-grid"><label className="field"><span>Returned units <b>*</b></span><input type="number" min={1} step={1} required value={form.returned_units} onChange={e => updateForm("returned_units", e.target.value)} /></label><label className="field"><span>Condition grade <b>*</b></span><select value={form.item_grade} onChange={e => updateForm("item_grade", e.target.value)} required>{gradeChoices.map(g => <option key={g} value={g}>{g}</option>)}</select></label>
            <label className="field"><span>Return date <small className="optional">Optional</small></span><div className="input-with-icon"><CalendarDays size={15} /><input type="date" value={form.return_date} onChange={e => updateForm("return_date", e.target.value)} /></div></label><label className="field"><span>Vendor-eligible units <b>*</b></span><input type="number" min={0} step={1} max={Number(form.returned_units) || undefined} required value={form.vendor_eligible_units} onChange={e => updateForm("vendor_eligible_units", e.target.value)} /><small>Enter the confirmed eligible quantity; it is not inferred from defect status.</small></label>
            <label className="field full"><span>Return reason <b>*</b></span><textarea value={form.return_reason} onChange={e => updateForm("return_reason", e.target.value)} required maxLength={3000} rows={3} placeholder="Describe the customer's return reason or observed issue…" /></label>
            <label className="field full"><span>Additional notes <small className="optional">Optional</small></span><textarea value={form.notes} onChange={e => updateForm("notes", e.target.value)} maxLength={3000} rows={2} placeholder="Inspection notes, packaging condition, or other context…" /></label>
            <label className="checkbox-field full"><input type="checkbox" checked={form.is_confirmed_defect} onChange={e => updateForm("is_confirmed_defect", e.target.checked)} /><span><strong>Defect confirmed</strong><small>Check only after inspection confirms a product defect. Supplier alerts remain controlled by your database logic.</small></span></label>
          </div>
          <div className="form-info"><Info size={15} /> Required fields are validated by this form and revalidated by the backend. Saving writes one record to your existing database.</div>
        </form>
      </div>
      <div className="modal-footer"><span><span className="required-dot">*</span> Required fields</span><div><button type="button" className="secondary" onClick={() => !saving && setIntakeOpen(false)} disabled={saving}>Cancel</button><button form="return-intake-form" type="submit" className="primary" disabled={saving || optionsLoading || products.length === 0}>{saving ? <LoaderCircle size={15} className="spin" /> : <Plus size={15} />}{saving ? "Saving…" : "Save return"}</button></div></div>
    </section></div>}

    {detailOpen && details && <div className="modal-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget) setDetailOpen(false); }}><section className="detail-modal" role="dialog" aria-modal="true" aria-labelledby="detail-title"><div className="modal-header"><div className="modal-heading-icon"><ClipboardList size={19} /></div><div className="modal-title-wrap"><div className="kicker">RETURN RECORD</div><h2 id="detail-title">{rowTracking(details)}</h2><p>{rowProduct(details)}</p></div><button className="modal-close" onClick={() => setDetailOpen(false)} aria-label="Close return details"><X size={18} /></button></div><div className="detail-body"><div className="detail-grid">{[["Supplier", rowSupplier(details)], ["Batch", rowBatch(details)], ["Condition", pretty(rowGrade(details))], ["Returned units", fmt(pick(details, ["returned_units", "units_returned"]))], ["Intake status", pretty(rowStatus(details))], ["Return date", pick(details, ["return_date"], "—")], ["Confirmed defect", pick(details, ["is_confirmed_defect"], null) === true ? "Yes" : pick(details, ["is_confirmed_defect"], null) === false ? "No" : "—"], ["Vendor-eligible units", fmt(pick(details, ["vendor_eligible_units"]))]].map(([label, value]) => <div className="detail-cell" key={String(label)}><span>{label}</span><strong>{String(value ?? "—")}</strong></div>)}</div><div className="detail-description"><span>Return reason</span><p>{pick(details, ["return_reason"], "No return reason returned by API.")}</p></div><div className="detail-description"><span>Notes</span><p>{pick(details, ["notes"], "No additional notes.")}</p></div><div className="detail-actions"><button className="secondary" onClick={() => { setSelectedId(String(pick(details, ["id", "return_id"], ""))); setRoutes([]); setRouteError(""); setDetailOpen(false); setSection("Recovery planning"); }}><Sparkles size={15} /> Evaluate recovery options</button></div></div></section></div>}
  </main>;
}

function SlidersHorizontalIcon() { return <Filter size={14} />; }
