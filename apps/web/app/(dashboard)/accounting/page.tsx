import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { financialYearStart, inr } from "@/lib/report-utils";
import { AccessGuard } from "@/components/shell/access-guard";

type Row = { ledger_name: string; group_name: string; nature: string; period_debit: number; period_credit: number; closing: number };
type Sp = { range?: string; from?: string; to?: string };
const ISO = /^\d{4}-\d{2}-\d{2}$/;

function iso(d: Date) {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

const RANGES = [
  { key: "today", label: "Today" },
  { key: "week", label: "This week" },
  { key: "month", label: "This month" },
  { key: "fy", label: "This FY" },
  { key: "custom", label: "Custom" },
];

function resolve(sp: Sp, now: Date) {
  const today = iso(now);
  const key = RANGES.some((r) => r.key === sp.range) ? (sp.range as string) : "month";
  if (key === "today") return { key, from: today, to: today };
  if (key === "week") { const d = new Date(now); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return { key, from: iso(d), to: today }; }
  if (key === "fy") return { key, from: financialYearStart(now), to: today };
  if (key === "custom" && sp.from && sp.to && ISO.test(sp.from) && ISO.test(sp.to)) {
    return sp.from <= sp.to ? { key, from: sp.from, to: sp.to } : { key, from: sp.to, to: sp.from };
  }
  return { key: "month", from: `${today.slice(0, 7)}-01`, to: today };
}

async function load(from: string, to: string): Promise<Row[]> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("trial_balance", { p_from: from, p_to: to });
  return (data ?? []).map((r: Record<string, unknown>) => ({
    ledger_name: String(r.ledger_name), group_name: String(r.group_name), nature: String(r.nature),
    period_debit: Number(r.period_debit), period_credit: Number(r.period_credit), closing: Number(r.closing),
  }));
}

// helpers over a trial-balance slice
const sales = (rows: Row[]) => rows.filter((r) => r.group_name === "Sales Accounts").reduce((s, r) => s + r.period_credit - r.period_debit, 0);
const expenses = (rows: Row[]) => rows.filter((r) => r.nature === "expense").reduce((s, r) => s + r.period_debit - r.period_credit, 0);
const income = (rows: Row[]) => rows.filter((r) => r.nature === "income").reduce((s, r) => s + r.period_credit - r.period_debit, 0);
const closing = (rows: Row[], f: (r: Row) => boolean) => rows.filter(f).reduce((s, r) => s + r.closing, 0);

export default async function AccountsHomePage({ searchParams }: { searchParams: Promise<Sp> }) {
  const sp = await searchParams;
  const now = new Date();
  const today = iso(now);
  const { key, from, to } = resolve(sp, now);
  const [sel, day, mon, fy] = await Promise.all([
    load(from, to), load(today, today), load(`${today.slice(0, 7)}-01`, today), load(financialYearStart(now), today),
  ]);

  // Balances are as on the end of the chosen period.
  const gstOut = -closing(sel, (r) => /Payable \(Output\)$/.test(r.ledger_name));
  const gstIn = closing(sel, (r) => /^Input (CGST|IGST|SGST)$/.test(r.ledger_name) || r.ledger_name === "GST Input Tax Credit (ITC)");
  const tds = -closing(sel, (r) => r.ledger_name === "TDS Payable");
  const cash = closing(sel, (r) => r.group_name === "Cash-in-Hand");
  const bank = closing(sel, (r) => r.group_name === "Bank Accounts");
  const debtors = closing(sel, (r) => r.group_name === "Sundry Debtors");
  const profitFy = income(fy) + sales(fy) - expenses(fy);

  const periodSales = sales(sel);
  const periodExp = expenses(sel);

  const card = "border border-line bg-surface p-4";
  const lbl = "text-xs text-ink-muted";
  const val = "mt-1 font-data text-xl font-semibold text-ink";
  const money = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));

  return (
    <AccessGuard gate="books_view">
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">Accounts</h1>
        <p className="mt-1 text-sm text-ink-muted">A quick view of sales, spending, tax and cash from your posted books.</p>

        <div className="mt-4 flex flex-wrap items-center gap-2">
          {RANGES.filter((r) => r.key !== "custom").map((r) => (
            <Link key={r.key} href={`/accounting?range=${r.key}`}
              className={`border px-3 py-1.5 text-sm ${key === r.key ? "border-accent bg-accent text-white" : "border-line bg-surface text-ink hover:bg-surface-sunken"}`}>{r.label}</Link>
          ))}
          <form method="get" className="flex flex-wrap items-center gap-2">
            <input type="hidden" name="range" value="custom" />
            <input type="date" name="from" defaultValue={from} className="h-9 border border-line bg-surface px-2 text-sm text-ink" />
            <input type="date" name="to" defaultValue={to} className="h-9 border border-line bg-surface px-2 text-sm text-ink" />
            <button type="submit" className={`border px-3 py-1.5 text-sm ${key === "custom" ? "border-accent bg-accent text-white" : "border-line bg-surface text-ink hover:bg-surface-sunken"}`}>Custom</button>
          </form>
        </div>
        <p className="mt-2 text-xs text-ink-muted">Showing {from} to {to}. Balances are as on {to}.</p>

        <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className={card}><p className={lbl}>Sales today</p><p className={val}>{money(sales(day))}</p></div>
          <div className={card}><p className={lbl}>Sales this month</p><p className={val}>{money(sales(mon))}</p></div>
          <div className={card}><p className={lbl}>Expenses today</p><p className={val}>{money(expenses(day))}</p></div>
          <div className={card}><p className={lbl}>Expenses this month</p><p className={val}>{money(expenses(mon))}</p></div>
        </div>

        <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className={card}><p className={lbl}>Sales in period</p><p className={val}>{money(periodSales)}</p></div>
          <div className={card}><p className={lbl}>Expenses in period</p><p className={val}>{money(periodExp)}</p></div>
          <Link href="/accounting/profit-and-loss" className={`${card} hover:bg-surface-sunken`}>
            <p className={lbl}>Net profit, this financial year</p>
            <p className={`${val} ${profitFy < 0 ? "text-danger" : ""}`}>{money(profitFy)}</p>
            <p className="mt-1 text-xs text-accent">Open Profit &amp; Loss</p>
          </Link>
          <Link href="/accounting/balance-sheet" className={`${card} hover:bg-surface-sunken`}>
            <p className={lbl}>Debtors (money to receive)</p><p className={val}>{money(debtors)}</p>
            <p className="mt-1 text-xs text-accent">Open Balance Sheet</p>
          </Link>
        </div>

        <h2 className="mt-8 text-sm font-semibold text-ink">Tax and cash</h2>
        <div className="mt-2 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <Link href="/gst" className={`${card} hover:bg-surface-sunken`}><p className={lbl}>GST collected (output)</p><p className={val}>{money(gstOut)}</p></Link>
          <Link href="/gst" className={`${card} hover:bg-surface-sunken`}><p className={lbl}>GST input credit</p><p className={val}>{money(gstIn)}</p></Link>
          <Link href="/gst" className={`${card} hover:bg-surface-sunken`}>
            <p className={lbl}>Net GST payable</p><p className={`${val} ${gstOut - gstIn < 0 ? "text-success" : ""}`}>{money(gstOut - gstIn)}</p>
            <p className="mt-1 text-xs text-ink-muted">{gstOut - gstIn < 0 ? "Credit exceeds tax collected" : "Output minus input"}</p>
          </Link>
          <div className={card}><p className={lbl}>TDS payable</p><p className={val}>{money(tds)}</p></div>
          <Link href="/accounting/day-book" className={`${card} hover:bg-surface-sunken`}><p className={lbl}>Cash balance</p><p className={val}>{money(cash)}</p></Link>
          <Link href="/accounting/ledgers" className={`${card} hover:bg-surface-sunken`}><p className={lbl}>Bank balance</p><p className={val}>{money(bank)}</p></Link>
        </div>

        <h2 className="mt-8 text-sm font-semibold text-ink">Quick actions</h2>
        <div className="mt-2 flex flex-wrap gap-2">
          {[
            ["New journal entry", "/accounting/journal"],
            ["View ledgers", "/accounting/ledgers"],
            ["Trial Balance", "/accounting/trial-balance"],
            ["Day Book", "/accounting/day-book"],
            ["GST Returns", "/gst"],
          ].map(([t, h]) => (
            <Link key={h} href={h} className="border border-line bg-surface px-3 py-2 text-sm text-ink hover:bg-surface-sunken">{t}</Link>
          ))}
        </div>
      </div>
    </AccessGuard>
  );
}
