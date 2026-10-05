"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { bookShipment, registerEinvoice, sendWhatsApp, trackShipment } from "@/lib/connectors/actions";

type Conn = { instance_id: string; label: string; mode: string };
export type Shipment = { awb: string; courier: string | null; status: string; mode: string; charge: number | null; instance_id: string | null };

export function ConnectedActions(p: {
  orderId: string; invoiceId: string | null; courier: Conn[]; gst: Conn[]; whatsapp: Conn[]; shipments: Shipment[]; einvoice: { irn: string; mode: string } | null;
  canShip: boolean; canEinvoice: boolean;
}) {
  const router = useRouter();
  const [pin, setPin] = useState("");
  const [wt, setWt] = useState("500");
  const [phone, setPhone] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run(key: string, f: () => Promise<{ ok: true; message: string } | { ok: false; error: string }>) {
    setBusy(key); setMsg(null); setErr(null);
    const r = await f();
    setBusy(null);
    if (r.ok) setMsg(r.message); else setErr(r.error);
    router.refresh();
  }
  const input = "h-9 border border-line bg-surface px-2.5 text-sm text-ink outline-none focus:border-accent";
  const btn = "border border-line bg-surface px-3 py-1.5 text-xs font-medium text-ink hover:bg-surface-sunken disabled:opacity-50";
  const tag = (m: string) => (m === "dummy" ? <span className="ml-1 border border-line px-1 text-[10px] uppercase text-ink-muted">dummy</span> : null);

  if (!p.courier.length && !p.gst.length && !p.whatsapp.length && !p.shipments.length) return null;
  return (
    <div className="mt-8">
      <h2 className="text-sm font-semibold text-ink">Shipping, e-invoice and messages</h2>
      <div className="mt-3 space-y-4 border border-line bg-surface p-5">
        {p.shipments.length > 0 ? (
          <ul className="space-y-2 text-sm">
            {p.shipments.map((s) => (
              <li key={s.awb} className="flex flex-wrap items-center justify-between gap-2">
                <span><span className="font-data">{s.awb}</span>{tag(s.mode)} · {s.courier ?? "courier"} · {s.status.replace(/_/g, " ")}{s.charge != null ? ` · ₹${s.charge}` : ""}</span>
                {s.instance_id ? <button className={btn} disabled={!!busy} onClick={() => run("t" + s.awb, () => trackShipment(s.instance_id!, p.orderId, s.awb))}>{busy === "t" + s.awb ? "…" : "Refresh tracking"}</button> : null}
              </li>
            ))}
          </ul>
        ) : null}

        {p.canShip && p.courier.length > 0 ? (
          <div className="flex flex-wrap items-end gap-2">
            <label className="text-xs text-ink-muted">Delivery pincode<br /><input className={`${input} w-28`} value={pin} onChange={(e) => setPin(e.target.value)} inputMode="numeric" maxLength={6} /></label>
            <label className="text-xs text-ink-muted">Weight (g)<br /><input className={`${input} w-24`} value={wt} onChange={(e) => setWt(e.target.value)} inputMode="numeric" /></label>
            <button className={btn} disabled={!!busy} onClick={() => run("book", () => bookShipment(p.courier[0].instance_id, p.orderId, { toPincode: pin, weightGrams: Number(wt) }))}>
              {busy === "book" ? "Booking…" : `Book courier (${p.courier[0].label}${p.courier[0].mode === "dummy" ? ", dummy" : ""})`}
            </button>
          </div>
        ) : null}

        {p.invoiceId && p.gst.length > 0 && p.canEinvoice ? (
          p.einvoice ? (
            <p className="text-sm text-ink">E-invoice IRN <span className="font-data text-xs">{p.einvoice.irn}</span>{tag(p.einvoice.mode)}</p>
          ) : (
            <button className={btn} disabled={!!busy} onClick={() => run("einv", () => registerEinvoice(p.gst[0].instance_id, p.invoiceId!))}>{busy === "einv" ? "Registering…" : `Register e-invoice (${p.gst[0].label})`}</button>
          )
        ) : null}

        {p.canShip && p.whatsapp.length > 0 ? (
          <div className="flex flex-wrap items-end gap-2">
            <label className="text-xs text-ink-muted">Customer WhatsApp number<br /><input className={`${input} w-44`} value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" placeholder="+91 98765 43210" /></label>
            <button className={btn} disabled={!!busy} onClick={() => run("wa", () => sendWhatsApp(p.whatsapp[0].instance_id, { to: phone, template: "order_update", orderId: p.orderId }))}>{busy === "wa" ? "Sending…" : "Send order update"}</button>
          </div>
        ) : null}
        {msg ? <p className="text-sm text-success">{msg}</p> : null}
        {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      </div>
    </div>
  );
}
