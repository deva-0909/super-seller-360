"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { beep } from "@/lib/scan/feedback";
import { ScanBox } from "@/components/scan/scan-box";
import { isSerial, stateText } from "@/lib/scan/serial";

type Ord = { order_id: string; external_order_id: string; fulfilment_status: string };
type Line = { product_id: string; sku: string; name: string; need: number };
type Unit = { serial: string; product_id: string; state: string };

export function PackOrder() {
  const supabase = useMemo(() => createClient(), []);
  const [q, setQ] = useState("");
  const [orders, setOrders] = useState<Ord[]>([]);
  const [order, setOrder] = useState<Ord | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [msg, setMsg] = useState<{ tone: "ok" | "bad"; text: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function search() {
    setErr(null); setOrder(null); setMsg(null);
    const t = q.trim();
    if (!t) return;
    const { data, error } = await supabase.from("orders").select("order_id, external_order_id, fulfilment_status").ilike("external_order_id", `%${t}%`).order("created_at", { ascending: false }).limit(10);
    if (error) { setErr(friendlyError(error.message)); return; }
    setOrders((data ?? []) as Ord[]);
    if (!data?.length) setErr("No order matches that number.");
  }
  async function load(o: Ord) {
    setOrder(o); setMsg(null); setErr(null);
    const [{ data: ls }, { data: us }] = await Promise.all([
      supabase.from("order_lines").select("product_id, quantity").eq("order_id", o.order_id).not("product_id", "is", null),
      supabase.from("item_units").select("serial, product_id, state").eq("order_id", o.order_id),
    ]);
    const ids = [...new Set((ls ?? []).map((l) => l.product_id as string))];
    const { data: ps } = ids.length ? await supabase.from("products").select("product_id, sku, name").in("product_id", ids) : { data: [] };
    const pm = new Map((ps ?? []).map((p) => [p.product_id, p]));
    const agg = new Map<string, number>();
    for (const l of ls ?? []) agg.set(l.product_id as string, (agg.get(l.product_id as string) ?? 0) + Number(l.quantity));
    setLines([...agg.entries()].map(([pid, need]) => ({ product_id: pid, sku: pm.get(pid)?.sku ?? "", name: pm.get(pid)?.name ?? "", need })));
    setUnits((us ?? []) as Unit[]);
  }
  async function scan(raw: string) {
    if (!order) return;
    const serial = raw.trim();
    if (!isSerial(serial)) { beep("bad"); setMsg({ tone: "bad", text: "That is not a piece serial. Scan the serial label (it starts with 21)." }); return; }
    const { error } = await supabase.rpc("order_pack_units", { p_order: order.order_id, p_serials: [serial] });
    if (error) { beep("bad"); setMsg({ tone: "bad", text: friendlyError(error.message) }); return; }
    beep("ok"); setMsg({ tone: "ok", text: `Piece ${serial.slice(-5)} added.` });
    await load(order);
  }
  async function unpack(serial: string) {
    const { error } = await supabase.rpc("order_unpack_unit", { p_serial: serial });
    if (error) { setMsg({ tone: "bad", text: friendlyError(error.message) }); return; }
    if (order) await load(order);
  }
  const tone = (t: string) => (t === "ok" ? "border-success bg-success-tint text-success" : "border-danger bg-danger-tint text-danger");
  return (
    <div className="space-y-4 border border-line bg-surface p-4">
      <div className="flex flex-wrap items-center gap-2">
        <input className="h-10 w-72 border border-line bg-surface px-2 text-sm text-ink" placeholder="Order number" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && void search()} />
        <button className="h-10 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken" onClick={() => void search()}>Find order</button>
      </div>
      {!order && orders.length ? <ul className="divide-y divide-line border border-line text-sm">{orders.map((o) => <li key={o.order_id} className="flex items-center justify-between px-3 py-2"><span className="font-data">{o.external_order_id} <span className="text-ink-muted">· {o.fulfilment_status}</span></span><button className="text-accent hover:underline" onClick={() => void load(o)}>Open</button></li>)}</ul> : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      {order ? (
        <div className="space-y-3">
          <p className="text-sm font-semibold text-ink">Order {order.external_order_id} <span className="font-normal text-ink-muted">· {order.fulfilment_status}</span></p>
          <ScanBox onScan={(c) => void scan(c)} />
          {msg ? <div className={`border-2 p-3 text-sm font-medium ${tone(msg.tone)}`} aria-live="polite">{msg.text}</div> : null}
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-2 font-medium">Item</th><th className="px-2 py-2 text-right font-medium">Ordered</th><th className="px-2 py-2 text-right font-medium">Scanned</th></tr></thead>
            <tbody>{lines.map((l) => {
              const got = units.filter((u) => u.product_id === l.product_id && ["packed", "sold"].includes(u.state)).length;
              return <tr key={l.product_id} className="border-b border-line/60"><td className="px-2 py-2"><span className="font-data">{l.sku}</span> <span className="text-ink-muted">· {l.name}</span></td><td className="px-2 py-2 text-right font-data">{l.need}</td><td className={`px-2 py-2 text-right font-data ${got === l.need ? "text-success" : ""}`}>{got}</td></tr>;
            })}</tbody>
          </table>
          {units.length ? <ul className="space-y-1 text-sm">{units.map((u) => <li key={u.serial} className="flex items-center gap-3"><span className="font-data">{u.serial}</span><span className="text-ink-muted">{stateText(u.state)}</span>{u.state === "packed" ? <button className="text-xs text-accent hover:underline" onClick={() => void unpack(u.serial)}>Take out</button> : null}</li>)}</ul> : null}
        </div>
      ) : null}
    </div>
  );
}
