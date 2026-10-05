"use client";

import { useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";
import { EXAMPLES, parseQuestion } from "@/lib/ask/intents";

type Answer = { title: string; summary: string; head: string[]; rows: (string | number)[][]; href?: string; hrefLabel?: string };
const sinceIso = (days: number) => new Date(Date.now() - days * 86400000).toISOString();

export function AskBox() {
  const supabase = createClient();
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const [ans, setAns] = useState<Answer | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function ask(text: string) {
    setBusy(true); setErr(null); setAns(null);
    try { setAns(await answer(text)); } catch (e) { setErr(friendlyError(e instanceof Error ? e.message : String(e))); }
    setBusy(false);
  }

  async function answer(text: string): Promise<Answer> {
    const p = parseQuestion(text);
    const since = sinceIso(p.days);
    const fail = (e: { message: string } | null) => { if (e) throw new Error(e.message); };
    switch (p.intent) {
      case "sales": {
        const { data, error } = await supabase.from("orders").select("net_amount, fulfilment_status, channels(name)").gte("order_date", since).neq("fulfilment_status", "cancelled").limit(10000);
        fail(error);
        const m = new Map<string, { n: number; v: number }>();
        for (const o of (data ?? []) as unknown as { net_amount: number; channels: { name: string } | null }[]) {
          const k = o.channels?.name ?? "Other"; const c = m.get(k) ?? { n: 0, v: 0 }; c.n += 1; c.v += Number(o.net_amount); m.set(k, c);
        }
        const rows = [...m.entries()].sort((a, b) => b[1].v - a[1].v).map(([k, c]) => [k, c.n, inr(c.v)]);
        const tot = [...m.values()].reduce((s, c) => ({ n: s.n + c.n, v: s.v + c.v }), { n: 0, v: 0 });
        return { title: `Sales, ${p.label}`, summary: `${tot.n} orders worth ${inr(tot.v)} (cancelled orders left out).`, head: ["Channel", "Orders", "Value"], rows };
      }
      case "top_products": {
        const { data, error } = await supabase.from("order_lines").select("quantity, unit_price, products(name, sku), orders!inner(order_date, fulfilment_status)").gte("orders.order_date", since).neq("orders.fulfilment_status", "cancelled").limit(10000);
        fail(error);
        const m = new Map<string, { sku: string; q: number; v: number }>();
        for (const l of (data ?? []) as unknown as { quantity: number; unit_price: number; products: { name: string; sku: string } | null }[]) {
          const k = l.products?.name ?? "Unknown"; const c = m.get(k) ?? { sku: l.products?.sku ?? "", q: 0, v: 0 };
          c.q += Number(l.quantity); c.v += Number(l.quantity) * Number(l.unit_price); m.set(k, c);
        }
        const rows = [...m.entries()].sort((a, b) => b[1].q - a[1].q).slice(0, 10).map(([k, c]) => [k, c.sku, c.q, inr(c.v)]);
        return { title: `Top products, ${p.label}`, summary: rows.length ? `Best seller: ${rows[0][0]}.` : "No sales in this period.", head: ["Product", "SKU", "Units", "Value"], rows };
      }
      case "low_stock": {
        const { data, error } = await supabase.from("reorder_suggestions").select("name, sku, on_hand, reserved, on_order, days_cover, suggested_qty").eq("needs_reorder", true).order("days_cover", { ascending: true, nullsFirst: true }).limit(25);
        fail(error);
        const rows = (data ?? []).map((r) => [r.name, r.sku, Number(r.on_hand), Number(r.on_order), r.days_cover == null ? "-" : `${r.days_cover} days`, Number(r.suggested_qty)]);
        return { title: "Running low", summary: rows.length ? `${rows.length} product(s) need re-ordering.` : "Nothing needs re-ordering right now (or no re-order levels are set yet).", head: ["Product", "SKU", "In stock", "On order", "Cover", "Suggested qty"], rows, href: "/purchases/reorder", hrefLabel: "Open re-order list" };
      }
      case "pending_orders": {
        const { data, error } = await supabase.from("orders").select("fulfilment_status").in("fulfilment_status", ["pending", "processing", "shipped"]).limit(10000);
        fail(error);
        const m = new Map<string, number>();
        for (const o of data ?? []) m.set(o.fulfilment_status, (m.get(o.fulfilment_status) ?? 0) + 1);
        const total = [...m.values()].reduce((a, b) => a + b, 0);
        return { title: "Orders not yet delivered", summary: `${total} order(s) in progress.`, head: ["Status", "Orders"], rows: [...m.entries()].map(([k, n]) => [k, n]), href: "/orders", hrefLabel: "Open orders" };
      }
      case "returns": {
        const { data, error } = await supabase.from("orders").select("net_amount, channels(name)").eq("fulfilment_status", "rto").gte("order_date", since).limit(10000);
        fail(error);
        const m = new Map<string, { n: number; v: number }>();
        for (const o of (data ?? []) as unknown as { net_amount: number; channels: { name: string } | null }[]) {
          const k = o.channels?.name ?? "Other"; const c = m.get(k) ?? { n: 0, v: 0 }; c.n += 1; c.v += Number(o.net_amount); m.set(k, c);
        }
        const rows = [...m.entries()].map(([k, c]) => [k, c.n, inr(c.v)]);
        return { title: `Returned to origin (RTO), ${p.label}`, summary: `${rows.reduce((s, r) => s + Number(r[1]), 0)} order(s) came back.`, head: ["Channel", "Orders", "Value"], rows };
      }
      case "anomalies": {
        const { data, error } = await supabase.from("anomalies").select("title, detail, n");
        fail(error);
        return { title: "Unusual things found", summary: (data ?? []).length ? "These need a look." : "Nothing unusual found.", head: ["What", "Details"], rows: (data ?? []).map((a) => [a.title, a.detail]), href: "/work-queue/anomalies", hrefLabel: "Open anomalies" };
      }
      case "work": {
        const { data, error } = await supabase.from("work_queue").select("title, category, severity, n").order("severity");
        fail(error);
        return { title: "Needs attention", summary: (data ?? []).length ? `${(data ?? []).length} item(s) waiting.` : "Nothing waiting. All clear.", head: ["What", "Area", "Priority", "Count"], rows: (data ?? []).map((w) => [w.title, w.category, w.severity, w.n]), href: "/work-queue", hrefLabel: "Open work queue" };
      }
      default:
        return { title: "I did not understand that", summary: "Try one of the examples below, e.g. \"sales in the last 30 days\".", head: [], rows: [] };
    }
  }

  return (
    <div className="mt-4 max-w-3xl">
      <form onSubmit={(e) => { e.preventDefault(); if (q.trim()) void ask(q); }} className="flex gap-2">
        <input className={inputCls} placeholder="e.g. Sales in the last 30 days" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className={primaryBtn} disabled={busy || !q.trim()}>{busy ? "Looking…" : "Ask"}</button>
      </form>
      <div className="mt-3 flex flex-wrap gap-2">
        {EXAMPLES.map((x) => <button key={x} type="button" className={smallBtn} disabled={busy} onClick={() => { setQ(x); void ask(x); }}>{x}</button>)}
      </div>
      {err ? <p className="mt-4 text-sm text-danger">{err}</p> : null}
      {ans ? (
        <div className="mt-4 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">{ans.title}</h2>
          <p className="mt-1 text-sm text-ink-muted">{ans.summary}</p>
          {ans.rows.length ? (
            <div className="mt-3 overflow-x-auto"><table className="w-full text-left text-sm">
              <thead><tr className="border-b border-line-strong text-xs text-ink-muted">{ans.head.map((h) => <th key={h} className="px-3 py-2 font-medium">{h}</th>)}</tr></thead>
              <tbody>{ans.rows.map((r, i) => <tr key={i} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>{r.map((c, j) => <td key={j} className="px-3 py-2">{c}</td>)}</tr>)}</tbody>
            </table></div>
          ) : null}
          {ans.href ? <Link href={ans.href} className="mt-3 inline-block text-sm text-accent hover:underline">{ans.hrefLabel}</Link> : null}
        </div>
      ) : null}
    </div>
  );
}
