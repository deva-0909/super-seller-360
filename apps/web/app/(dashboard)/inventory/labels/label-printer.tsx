"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { ean13Svg } from "@/lib/codes/ean13";
import { qrSvg } from "@/lib/codes/qr";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export type LabelProduct = {
  product_id: string; sku: string; name: string; size: string | null; colour: string | null; category: string | null; internal_code: string; main_barcode: string | null; status: string;
  codes: { code_id: string; code: string; kind: string; pack_qty: number }[]; printed_copies: number; last_printed: string | null;
};
const SIZES = {
  roll50: { label: "Roll label 50 × 25 mm", w: 50, h: 25, sheet: false },
  roll70: { label: "Roll label 70 × 35 mm", w: 70, h: 35, sheet: false },
  a4: { label: "A4 sheet, 3 × 8 labels (70 × 37 mm)", w: 70, h: 37, sheet: true },
} as const;
type SizeKey = keyof typeof SIZES;
const inputCls = "h-9 border border-line bg-surface px-2 text-sm text-ink";
const btn = "h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";

function Label({ p, w, h }: { p: LabelProduct; w: number; h: number }) {
  // codes are drawn by our own code (lib/codes), no outside package or service
  const bar = useMemo(() => { try { return ean13Svg(p.internal_code, { height: h > 30 ? 34 : 24 }); } catch { return ""; } }, [p.internal_code, h]);
  const qr = useMemo(() => { try { return qrSvg(p.internal_code); } catch { return ""; } }, [p.internal_code]);
  const sub = [p.sku, p.size, p.colour].filter(Boolean).join(" · ");
  return (
    <div className="label-item flex items-stretch justify-between gap-1 overflow-hidden border border-dashed border-line bg-white p-1 text-black" style={{ width: `${w}mm`, height: `${h}mm`, breakInside: "avoid" }}>
      <div className="flex min-w-0 flex-1 flex-col justify-between">
        <div className="min-w-0"><p className="line-clamp-2 text-[9px] font-semibold leading-tight">{p.name}</p><p className="truncate text-[8px] leading-tight">{sub}</p></div>
        <div className="min-h-0 flex-1" dangerouslySetInnerHTML={{ __html: bar }} />
      </div>
      <div className="h-full shrink-0" style={{ width: `${Math.min(h - 4, 22)}mm` }} dangerouslySetInnerHTML={{ __html: qr }} />
    </div>
  );
}

function Codes({ p, canPrint }: { p: LabelProduct; canPrint: boolean }) {
  const router = useRouter();
  const [code, setCode] = useState("");
  const [kind, setKind] = useState("supplier");
  const [pack, setPack] = useState("12");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function add() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("product_code_link", { p_code: code, p_product: p.product_id, p_kind: kind, p_pack_qty: kind === "carton" ? Number(pack) || 1 : 1 });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setCode(""); router.refresh();
  }
  async function remove(id: string) {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("product_code_unlink", { p_code_id: id });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <div className="space-y-2 bg-surface-sunken/50 px-3 py-3 text-sm">
      <p className="text-ink-muted">Our code: <span className="font-data text-ink">{p.internal_code}</span>{p.main_barcode ? <> · main barcode: <span className="font-data text-ink">{p.main_barcode}</span></> : null}</p>
      {p.codes.length ? <ul className="space-y-1">{p.codes.map((c) => (
        <li key={c.code_id} className="flex items-center gap-3"><span className="font-data">{c.code}</span><span className="text-ink-muted">{c.kind}{c.pack_qty > 1 ? ` · ${c.pack_qty} pcs` : ""}</span>
          {canPrint ? <button className="text-xs text-accent hover:underline" disabled={busy} onClick={() => remove(c.code_id)}>Remove</button> : null}</li>))}</ul>
        : <p className="text-ink-muted">No supplier or carton codes linked yet.</p>}
      {canPrint ? (
        <div className="flex flex-wrap items-end gap-2">
          <input className={`${inputCls} w-52`} placeholder="Scan or type the supplier's code" value={code} onChange={(e) => setCode(e.target.value)} />
          <select className={inputCls} value={kind} onChange={(e) => setKind(e.target.value)}><option value="supplier">Supplier barcode</option><option value="carton">Carton barcode</option></select>
          {kind === "carton" ? <input className={`${inputCls} w-20`} inputMode="numeric" value={pack} onChange={(e) => setPack(e.target.value)} title="Pieces in the carton" /> : null}
          <button className={btn} disabled={busy || !code.trim()} onClick={add}>Link code</button>
        </div>
      ) : null}
      {err ? <p className="text-xs text-danger">{err}</p> : null}
    </div>
  );
}

export function LabelPrinter({ products, canPrint }: { products: LabelProduct[]; canPrint: boolean }) {
  const router = useRouter();
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<"all" | "never">("all");
  const [size, setSize] = useState<SizeKey>("roll50");
  const [copies, setCopies] = useState<Record<string, number>>({});
  const [open, setOpen] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const shown = useMemo(() => {
    const s = q.trim().toLowerCase();
    return products.filter((p) => (filter === "all" || p.printed_copies === 0) && (!s || `${p.sku} ${p.name} ${p.category ?? ""} ${p.colour ?? ""} ${p.size ?? ""} ${p.internal_code}`.toLowerCase().includes(s)));
  }, [products, q, filter]);
  const picked = products.filter((p) => (copies[p.product_id] ?? 0) > 0);
  const total = picked.reduce((t, p) => t + (copies[p.product_id] ?? 0), 0);
  const sz = SIZES[size];
  const set = (id: string, n: number) => setCopies((c) => ({ ...c, [id]: Math.max(0, Math.min(10000, Math.floor(n) || 0)) }));

  async function print() {
    setErr(null);
    const { error } = await createClient().rpc("labels_log", { p_items: picked.map((p) => ({ product_id: p.product_id, copies: copies[p.product_id] })) });
    if (error) { setErr(friendlyError(error.message)); return; }
    setTimeout(() => { window.print(); router.refresh(); }, 150);
  }
  const pageCss = sz.sheet ? "@page { size: A4; margin: 10mm; }" : `@page { size: ${sz.w}mm ${sz.h}mm; margin: 0; }`;
  const sheetStyle = sz.sheet ? { display: "grid", gridTemplateColumns: `repeat(3, ${sz.w}mm)`, gap: 0 } : undefined;
  return (
    <div className="space-y-4">
      <style>{`${pageCss} @media print { body * { visibility: hidden !important; } .label-sheet, .label-sheet * { visibility: visible !important; } .label-sheet { position: absolute; left: 0; top: 0; } .label-item { border: none !important; ${sz.sheet ? "" : "page-break-after: always;"} } }`}</style>
      <div className="flex flex-wrap items-end gap-3 print:hidden">
        <input className={`${inputCls} w-64`} placeholder="Search SKU, name, colour, code…" value={q} onChange={(e) => setQ(e.target.value)} />
        <select className={inputCls} value={filter} onChange={(e) => setFilter(e.target.value as "all" | "never")}><option value="all">All products</option><option value="never">Never printed</option></select>
        <select className={inputCls} value={size} onChange={(e) => setSize(e.target.value as SizeKey)}>{(Object.keys(SIZES) as SizeKey[]).map((k) => <option key={k} value={k}>{SIZES[k].label}</option>)}</select>
        <button className={btn} onClick={() => setCopies(Object.fromEntries(shown.map((p) => [p.product_id, 1])))}>1 label for each shown</button>
        <button className={btn} onClick={() => setCopies({})}>Clear</button>
        <button className="h-9 rounded-lg bg-accent px-4 text-sm font-semibold text-white disabled:opacity-50" disabled={!canPrint || total === 0} onClick={print}>Print {total} label{total === 1 ? "" : "s"}</button>
      </div>
      {!canPrint ? <p className="text-sm text-ink-muted print:hidden">Your role can view codes but not print labels.</p> : null}
      {err ? <p role="alert" className="text-sm text-danger print:hidden">{err}</p> : null}

      <div className="overflow-x-auto border border-line bg-surface print:hidden">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">Product</th><th className="px-3 py-2 font-medium">Our code</th><th className="px-3 py-2 text-right font-medium">Linked codes</th><th className="px-3 py-2 font-medium">Printed</th><th className="px-3 py-2 text-right font-medium">Labels to print</th></tr></thead>
          <tbody>
            {shown.slice(0, 300).map((p) => (
              <FragmentRow key={p.product_id} p={p} n={copies[p.product_id] ?? 0} set={set} open={open === p.product_id} toggle={() => setOpen(open === p.product_id ? null : p.product_id)} canPrint={canPrint} />
            ))}
            {!shown.length ? <tr><td colSpan={5} className="px-3 py-6 text-center text-ink-muted">No products match.</td></tr> : null}
          </tbody>
        </table>
        {shown.length > 300 ? <p className="px-3 py-2 text-xs text-ink-muted">Showing the first 300 of {shown.length}. Narrow the search.</p> : null}
      </div>

      {picked.length ? (
        <div className="print:p-0">
          <p className="mb-2 text-xs text-ink-muted print:hidden">Preview of what will print ({sz.label}). Dashed lines do not print.</p>
          <div className="label-sheet flex flex-wrap gap-2 print:gap-0" style={sheetStyle}>
            {picked.flatMap((p) => Array.from({ length: Math.min(copies[p.product_id] ?? 0, 500) }, (_, i) => <Label key={`${p.product_id}-${i}`} p={p} w={sz.w} h={sz.h} />))}
          </div>
        </div>
      ) : null}
    </div>
  );
}

function FragmentRow({ p, n, set, open, toggle, canPrint }: { p: LabelProduct; n: number; set: (id: string, n: number) => void; open: boolean; toggle: () => void; canPrint: boolean }) {
  return (
    <>
      <tr className="border-b border-line/60">
        <td className="px-3 py-2"><span className="font-data">{p.sku}</span> <span className="text-ink-muted">· {p.name}{p.size ? ` · ${p.size}` : ""}{p.colour ? ` · ${p.colour}` : ""}</span></td>
        <td className="px-3 py-2 font-data">{p.internal_code}</td>
        <td className="px-3 py-2 text-right"><button className="text-accent hover:underline" onClick={toggle}>{p.codes.length + (p.main_barcode ? 1 : 0)} {open ? "▲" : "▼"}</button></td>
        <td className="px-3 py-2 text-ink-muted">{p.printed_copies ? `${p.printed_copies} (last ${p.last_printed})` : "Never"}</td>
        <td className="px-3 py-2 text-right"><input className={`${inputCls} w-20 text-right`} inputMode="numeric" value={n || ""} placeholder="0" onChange={(e) => set(p.product_id, Number(e.target.value))} /></td>
      </tr>
      {open ? <tr><td colSpan={5} className="p-0"><Codes p={p} canPrint={canPrint} /></td></tr> : null}
    </>
  );
}
