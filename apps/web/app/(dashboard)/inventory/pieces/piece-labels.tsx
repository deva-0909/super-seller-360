"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { ean13Svg } from "@/lib/codes/ean13";
import { qrSvg } from "@/lib/codes/qr";

export type UnitToPrint = { unit_id: string; serial: string; product_id: string; sku: string; name: string; size: string | null; colour: string | null; group: string; received: string };
const SIZES = {
  roll50: { label: "Roll label 50 × 25 mm", w: 50, h: 25, sheet: false },
  roll70: { label: "Roll label 70 × 35 mm", w: 70, h: 35, sheet: false },
  a4: { label: "A4 sheet, 3 × 8 labels (70 × 37 mm)", w: 70, h: 37, sheet: true },
} as const;
type SizeKey = keyof typeof SIZES;
const inputCls = "h-9 border border-line bg-surface px-2 text-sm text-ink";
const MAX = 500;

function Face({ u, w, h }: { u: UnitToPrint; w: number; h: number }) {
  const bar = useMemo(() => { try { return ean13Svg(u.serial, { height: h > 30 ? 34 : 24 }); } catch { return ""; } }, [u.serial, h]);
  const qr = useMemo(() => { try { return qrSvg(u.serial); } catch { return ""; } }, [u.serial]);
  const sub = [u.sku, u.size, u.colour].filter(Boolean).join(" · ");
  return (
    <div className="label-item flex items-stretch justify-between gap-1 overflow-hidden border border-dashed border-line bg-white p-1 text-black" style={{ width: `${w}mm`, height: `${h}mm`, breakInside: "avoid" }}>
      <div className="flex min-w-0 flex-1 flex-col justify-between">
        <div className="min-w-0"><p className="line-clamp-2 text-[9px] font-semibold leading-tight">{u.name}</p><p className="truncate text-[8px] leading-tight">{sub}</p></div>
        <div className="min-h-0 flex-1" dangerouslySetInnerHTML={{ __html: bar }} />
      </div>
      <div className="h-full shrink-0" style={{ width: `${Math.min(h - 4, 22)}mm` }} dangerouslySetInnerHTML={{ __html: qr }} />
    </div>
  );
}

export function PieceLabels({ units, canPrint }: { units: UnitToPrint[]; canPrint: boolean }) {
  const router = useRouter();
  const [size, setSize] = useState<SizeKey>("roll50");
  const [picked, setPicked] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const groups = useMemo(() => {
    const m = new Map<string, UnitToPrint[]>();
    for (const u of units) m.set(u.group, [...(m.get(u.group) ?? []), u]);
    return [...m.entries()].map(([k, list]) => ({ key: k, list }));
  }, [units]);
  const sel = groups.find((g) => g.key === picked)?.list.slice(0, MAX) ?? [];
  const sz = SIZES[size];

  async function print() {
    setErr(null);
    const { error } = await createClient().rpc("unit_labels_printed", { p_units: sel.map((u) => u.unit_id) });
    if (error) { setErr(friendlyError(error.message)); return; }
    setTimeout(() => { window.print(); setPicked(null); router.refresh(); }, 150);
  }
  const pageCss = sz.sheet ? "@page { size: A4; margin: 10mm; }" : `@page { size: ${sz.w}mm ${sz.h}mm; margin: 0; }`;
  const sheetStyle = sz.sheet ? { display: "grid", gridTemplateColumns: `repeat(3, ${sz.w}mm)`, gap: 0 } : undefined;
  return (
    <div className="space-y-3">
      <style>{`${pageCss} @media print { body * { visibility: hidden !important; } .label-sheet, .label-sheet * { visibility: visible !important; } .label-sheet { position: absolute; left: 0; top: 0; } .label-item { border: none !important; ${sz.sheet ? "" : "page-break-after: always;"} } }`}</style>
      <div className="flex flex-wrap items-center gap-3 print:hidden">
        <select className={inputCls} value={size} onChange={(e) => setSize(e.target.value as SizeKey)}>{(Object.keys(SIZES) as SizeKey[]).map((k) => <option key={k} value={k}>{SIZES[k].label}</option>)}</select>
        <button className="h-9 rounded-lg bg-accent px-4 text-sm font-semibold text-white disabled:opacity-50" disabled={!canPrint || !sel.length} onClick={print}>Print {sel.length} serial label{sel.length === 1 ? "" : "s"}</button>
        {sel.length === MAX ? <span className="text-xs text-ink-muted">{MAX} at a time. Press again for the rest.</span> : null}
        {err ? <span role="alert" className="text-sm text-danger">{err}</span> : null}
      </div>
      <div className="overflow-x-auto border border-line bg-surface print:hidden">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">Received</th><th className="px-3 py-2 font-medium">Product</th><th className="px-3 py-2 text-right font-medium">Labels to print</th><th className="px-3 py-2" /></tr></thead>
          <tbody>
            {groups.map((g) => (
              <tr key={g.key} className={`border-b border-line/60 ${picked === g.key ? "bg-surface-sunken" : ""}`}>
                <td className="px-3 py-2 font-data">{g.list[0].received}</td>
                <td className="px-3 py-2"><span className="font-data">{g.list[0].sku}</span> <span className="text-ink-muted">· {g.list[0].name}{g.list[0].size ? ` · ${g.list[0].size}` : ""}{g.list[0].colour ? ` · ${g.list[0].colour}` : ""}</span></td>
                <td className="px-3 py-2 text-right font-data">{g.list.length}</td>
                <td className="px-3 py-2 text-right"><button className="text-accent hover:underline" onClick={() => setPicked(picked === g.key ? null : g.key)}>{picked === g.key ? "Unselect" : "Select"}</button></td>
              </tr>
            ))}
            {!groups.length ? <tr><td colSpan={4} className="px-3 py-6 text-center text-ink-muted">Nothing waiting. Labels appear here when goods are received.</td></tr> : null}
          </tbody>
        </table>
      </div>
      {sel.length ? (
        <div>
          <p className="mb-2 text-xs text-ink-muted print:hidden">Preview of what will print ({sz.label}). Dashed lines do not print.</p>
          <div className="label-sheet flex flex-wrap gap-2 print:gap-0" style={sheetStyle}>{sel.map((u) => <Face key={u.unit_id} u={u} w={sz.w} h={sz.h} />)}</div>
        </div>
      ) : null}
    </div>
  );
}
