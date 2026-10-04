"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { gstinValid } from "@/lib/purchase-calc";
import { Lbl, inputCls, primaryBtn } from "@/components/purchases/bits";

export type SupplierInit = {
  supplier_id?: string; name?: string; trade_name?: string | null; gstin?: string | null; pan?: string | null; state_code?: string;
  is_msme?: boolean; msme_reg_no?: string | null; payment_terms_days?: number; tds_section?: string | null; tds_rate_override?: number | null;
  email?: string | null; phone?: string | null; address?: string | null;
  bank_name?: string | null; ifsc?: string | null; account_number?: string | null; account_holder?: string | null;
};

export function SupplierForm({ init, states, sections, showBank }: {
  init?: SupplierInit; states: { code: string; name: string }[]; sections: { section: string; description: string }[]; showBank: boolean;
}) {
  const router = useRouter();
  const [f, setF] = useState({
    name: init?.name ?? "", trade_name: init?.trade_name ?? "", gstin: init?.gstin ?? "", pan: init?.pan ?? "", state_code: init?.state_code ?? "24",
    is_msme: init?.is_msme ?? false, msme_reg_no: init?.msme_reg_no ?? "", payment_terms_days: String(init?.payment_terms_days ?? 30),
    tds_section: init?.tds_section ?? "", tds_rate_override: init?.tds_rate_override != null ? String(init.tds_rate_override) : "",
    email: init?.email ?? "", phone: init?.phone ?? "", address: init?.address ?? "",
    bank_name: init?.bank_name ?? "", ifsc: init?.ifsc ?? "", account_number: init?.account_number ?? "", account_holder: init?.account_holder ?? "",
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const set = (k: keyof typeof f, v: string | boolean) => setF((p) => ({ ...p, [k]: v }));
  const g = f.gstin.trim().toUpperCase();
  const gOk = g === "" || gstinValid(g);

  function onGstin(v: string) {
    const u = v.toUpperCase().replace(/\s/g, "");
    setF((p) => {
      const next = { ...p, gstin: u };
      if (u.length === 15 && gstinValid(u)) {
        next.pan = u.slice(2, 12);
        if (states.some((s) => s.code === u.slice(0, 2))) next.state_code = u.slice(0, 2);
      }
      return next;
    });
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (!gOk) { setErr("That GSTIN does not look right. Check it against the supplier's invoice."); return; }
    setBusy(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("supplier_save", {
      p_id: init?.supplier_id ?? null,
      p: { ...f, gstin: g || null, pan: f.pan.trim().toUpperCase() || null, payment_terms_days: Number(f.payment_terms_days || 30),
           tds_section: f.tds_section || null, tds_rate_override: f.tds_rate_override === "" ? null : Number(f.tds_rate_override) },
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/purchases/suppliers/${data as string}`);
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="mt-6 flex max-w-3xl flex-col gap-6">
      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Lbl label="Supplier name *"><input className={inputCls} value={f.name} onChange={(e) => set("name", e.target.value)} required /></Lbl>
        <Lbl label="Trade name"><input className={inputCls} value={f.trade_name} onChange={(e) => set("trade_name", e.target.value)} /></Lbl>
        <Lbl label="GSTIN" hint={g && !gOk ? "Not a valid GSTIN" : "Leave empty for an unregistered supplier (no GST can be charged)."}>
          <input className={`${inputCls} ${gOk ? "" : "border-danger"}`} value={f.gstin} maxLength={15} onChange={(e) => onGstin(e.target.value)} autoCapitalize="characters" />
        </Lbl>
        <Lbl label="PAN" hint="Filled from the GSTIN. Without a PAN, TDS is deducted at the higher rate."><input className={inputCls} value={f.pan} maxLength={10} onChange={(e) => set("pan", e.target.value.toUpperCase())} /></Lbl>
        <Lbl label="State *">
          <select className={inputCls} value={f.state_code} onChange={(e) => set("state_code", e.target.value)} disabled={g.length === 15 && gOk}>
            {states.map((s) => <option key={s.code} value={s.code}>{s.code} · {s.name}</option>)}
          </select>
        </Lbl>
        <Lbl label="Payment terms (days)" hint="Due date = invoice date + this."><input className={inputCls} type="number" min={0} max={365} value={f.payment_terms_days} onChange={(e) => set("payment_terms_days", e.target.value)} /></Lbl>
      </section>

      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <label className="flex items-center gap-2 text-sm font-medium text-ink sm:col-span-2">
          <input type="checkbox" checked={f.is_msme} onChange={(e) => set("is_msme", e.target.checked)} className="h-5 w-5" /> Micro or small enterprise (MSME)
        </label>
        {f.is_msme ? <Lbl label="Udyam registration no." hint="Payment to an MSME is watched against the 45-day limit."><input className={inputCls} value={f.msme_reg_no} onChange={(e) => set("msme_reg_no", e.target.value)} /></Lbl> : null}
        <Lbl label="TDS section" hint="Choose only if TDS applies to what this supplier does. Confirm with your CA.">
          <select className={inputCls} value={f.tds_section} onChange={(e) => set("tds_section", e.target.value)}>
            <option value="">No TDS</option>
            {sections.map((s) => <option key={s.section} value={s.section}>{s.section} · {s.description}</option>)}
          </select>
        </Lbl>
        {f.tds_section ? <Lbl label="Lower-deduction rate % (certificate)" hint="Only if the supplier gave you a certificate."><input className={inputCls} type="number" step="0.01" min={0} max={100} value={f.tds_rate_override} onChange={(e) => set("tds_rate_override", e.target.value)} /></Lbl> : null}
      </section>

      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Lbl label="Phone"><input className={inputCls} type="tel" value={f.phone} onChange={(e) => set("phone", e.target.value)} /></Lbl>
        <Lbl label="Email"><input className={inputCls} type="email" value={f.email} onChange={(e) => set("email", e.target.value)} /></Lbl>
        <Lbl label="Address" className="sm:col-span-2"><input className={inputCls} value={f.address} onChange={(e) => set("address", e.target.value)} /></Lbl>
      </section>

      {showBank ? (
        <section className="grid grid-cols-1 gap-4 border border-line bg-surface p-4 sm:grid-cols-2">
          <p className="text-sm font-semibold text-ink sm:col-span-2">Bank details</p>
          <Lbl label="Account holder"><input className={inputCls} value={f.account_holder} onChange={(e) => set("account_holder", e.target.value)} /></Lbl>
          <Lbl label="Bank"><input className={inputCls} value={f.bank_name} onChange={(e) => set("bank_name", e.target.value)} /></Lbl>
          <Lbl label="Account number"><input className={inputCls} inputMode="numeric" value={f.account_number} onChange={(e) => set("account_number", e.target.value.replace(/\D/g, ""))} /></Lbl>
          <Lbl label="IFSC"><input className={inputCls} value={f.ifsc} maxLength={11} onChange={(e) => set("ifsc", e.target.value.toUpperCase())} /></Lbl>
          <p className="text-xs text-ink-muted sm:col-span-2">Changing the GSTIN, TDS settings or bank account of an approved supplier sends it back for approval by a second person.</p>
        </section>
      ) : null}

      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : init?.supplier_id ? "Save changes" : "Save supplier"}</button></div>
    </form>
  );
}
