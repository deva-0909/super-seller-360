import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseRange, inr } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";

type Row = {
  ledger_id: string; ledger_name: string; group_name: string; nature: string;
  opening: number; period_debit: number; period_credit: number; closing: number;
};
type Sp = { fy?: string; from?: string; to?: string };

const NATURE_ORDER = ["asset", "liability", "equity", "income", "expense"];
const NATURE_STYLE: Record<string, { label: string; head: string }> = {
  asset: { label: "Assets", head: "bg-blue-50 text-blue-900 dark:bg-blue-950/40 dark:text-blue-200" },
  liability: { label: "Liabilities", head: "bg-red-50 text-red-900 dark:bg-red-950/40 dark:text-red-200" },
  equity: { label: "Equity", head: "bg-purple-50 text-purple-900 dark:bg-purple-950/40 dark:text-purple-200" },
  income: { label: "Income", head: "bg-green-50 text-green-900 dark:bg-green-950/40 dark:text-green-200" },
  expense: { label: "Expenses", head: "bg-amber-50 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200" },
};

const dr = (n: number) => (n > 0 ? n : 0);
const cr = (n: number) => (n < 0 ? -n : 0);
const zero = () => ({ od: 0, oc: 0, d: 0, c: 0, cd: 0, cc: 0 });
type Tot = ReturnType<typeof zero>;
const add = (t: Tot, r: Row): Tot => ({
  od: t.od + dr(r.opening), oc: t.oc + cr(r.opening), d: t.d + r.period_debit, c: t.c + r.period_credit,
  cd: t.cd + dr(r.closing), cc: t.cc + cr(r.closing),
});

export default async function TrialBalancePage({ searchParams }: { searchParams: Promise<Sp> }) {
  const sp = await searchParams;
  const now = new Date();
  const curFy = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1;
  const fyOptions = Array.from({ length: 6 }, (_, i) => curFy - i);
  // Financial year + "as on" date; an explicit from/to in the address still works for old links.
  const fyNum = sp.fy && /^\d{4}$/.test(sp.fy) ? Number(sp.fy) : null;
  let from: string, to: string;
  if (fyNum && !sp.from) {
    const fyEnd = `${fyNum + 1}-03-31`;
    const asOn = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : null;
    from = `${fyNum}-04-01`;
    to = asOn && asOn >= from && asOn <= fyEnd ? asOn : (fyNum === curFy ? parseRange({}, now).to : fyEnd);
  } else {
    ({ from, to } = parseRange(sp, now));
  }
  const selFy = Number(from.slice(5, 7)) >= 4 ? Number(from.slice(0, 4)) : Number(from.slice(0, 4)) - 1;

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("trial_balance", { p_from: from, p_to: to });
  const rows: Row[] = (data ?? []).map((r: Record<string, unknown>) => ({
    ledger_id: String(r.ledger_id), ledger_name: String(r.ledger_name), group_name: String(r.group_name), nature: String(r.nature),
    opening: Number(r.opening), period_debit: Number(r.period_debit), period_credit: Number(r.period_credit), closing: Number(r.closing),
  }));

  // nature → group → rows
  const natures = [...new Set(rows.map((r) => r.nature))].sort((a, b) => {
    const ia = NATURE_ORDER.indexOf(a), ib = NATURE_ORDER.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });
  const tot = rows.reduce(add, zero());
  const balanced = Math.abs(tot.cd - tot.cc) < 0.01;

  const csv: (string | number)[][] = [
    ["Trial balance", `${from} to ${to}`],
    ["Head", "Ledger", "Opening Dr", "Opening Cr", "Period Dr", "Period Cr", "Closing Dr", "Closing Cr"],
  ];
  const body = natures.map((nat) => {
    const inNat = rows.filter((r) => r.nature === nat);
    const groups = [...new Set(inNat.map((r) => r.group_name))].sort();
    return { nat, groups: groups.map((g) => {
      const list = inNat.filter((r) => r.group_name === g);
      return { g, list, sub: list.reduce(add, zero()) };
    }) };
  });
  for (const n of body) for (const g of n.groups) {
    for (const r of g.list) csv.push([g.g, r.ledger_name, dr(r.opening), cr(r.opening), r.period_debit, r.period_credit, dr(r.closing), cr(r.closing)]);
    csv.push([`Subtotal — ${g.g}`, "", g.sub.od, g.sub.oc, g.sub.d, g.sub.c, g.sub.cd, g.sub.cc]);
  }
  csv.push(["GRAND TOTAL", "", tot.od, tot.oc, tot.d, tot.c, tot.cd, tot.cc]);

  const num = "px-4 py-2.5 text-right font-data";
  const th = "px-4 py-3 font-medium text-right";

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Trial Balance</h1>
          <p className="mt-1 text-sm text-ink-muted">
            Every ledger grouped by account head, with opening, period and closing balances. Posted vouchers only.
          </p>
        </div>
        <CsvButton rows={csv} filename={`trial-balance-${from}-to-${to}`} />
      </div>

      <form method="get" className="mt-4 flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1 text-xs text-ink-muted">
          Financial year
          <select name="fy" defaultValue={String(selFy)} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink">
            {fyOptions.map((y) => <option key={y} value={y}>FY {y}-{String(y + 1).slice(2)}</option>)}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">
          As on
          <input type="date" name="to" defaultValue={to} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink" />
        </label>
        <button type="submit" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Show</button>
        <span className="pb-2 text-xs text-ink-muted">Period: {from} to {to}</span>
      </form>

      {error ? <p className="mt-4 text-sm text-danger">Could not load the trial balance: {error.message}</p> : null}
      {!balanced && !error ? (
        <p role="alert" className="mt-4 border border-danger/40 bg-danger-tint p-3 text-sm font-medium text-danger">
          Out of balance by {inr(Math.abs(tot.cd - tot.cc))}. Check the opening balances entered on the ledgers: they must total zero between debit and credit.
        </p>
      ) : null}

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Account</th>
              <th className={th}>Opening Dr</th><th className={th}>Opening Cr</th>
              <th className={th}>Period Dr</th><th className={th}>Period Cr</th>
              <th className={th}>Closing Dr</th><th className={th}>Closing Cr</th>
            </tr>
          </thead>
          <tbody>
            {body.map((n) => {
              const st = NATURE_STYLE[n.nat] ?? { label: n.nat, head: "bg-surface-sunken text-ink" };
              return n.groups.map((g) => (
                <GroupRows key={`${n.nat}-${g.g}`} title={g.g} natureLabel={st.label} headClass={st.head} list={g.list} sub={g.sub} from={from} to={to} num={num} />
              ));
            })}
            {!rows.length && !error ? (
              <tr><td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-muted">Nothing posted yet.</td></tr>
            ) : null}
          </tbody>
          <tfoot>
            <tr className="bg-ink text-sm font-semibold text-surface">
              <td className="px-4 py-3">GRAND TOTAL</td>
              <td className={num}>{inr(tot.od)}</td><td className={num}>{inr(tot.oc)}</td>
              <td className={num}>{inr(tot.d)}</td><td className={num}>{inr(tot.c)}</td>
              <td className={num}>{inr(tot.cd)}</td><td className={num}>{inr(tot.cc)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      {balanced && !error ? <p className="mt-3 text-sm font-medium text-success">Balanced: closing debits equal closing credits.</p> : null}
    </div>
  );
}

function GroupRows({ title, natureLabel, headClass, list, sub, from, to, num }: {
  title: string; natureLabel: string; headClass: string; list: Row[]; sub: Tot; from: string; to: string; num: string;
}) {
  return (
    <>
      <tr className={headClass}>
        <td colSpan={7} className="px-4 py-2 text-xs font-semibold uppercase tracking-wide">{natureLabel} · {title}</td>
      </tr>
      {list.map((r) => (
        <tr key={r.ledger_id} className="border-b border-line/60">
          <td className="px-4 py-2.5 pl-8">
            <Link href={`/accounting/ledgers/${r.ledger_id}?from=${from}&to=${to}`} className="text-accent hover:underline">{r.ledger_name}</Link>
          </td>
          <td className={`${num} text-ink-muted`}>{inr(dr(r.opening))}</td>
          <td className={`${num} text-ink-muted`}>{inr(cr(r.opening))}</td>
          <td className={`${num} text-ink-muted`}>{inr(r.period_debit)}</td>
          <td className={`${num} text-ink-muted`}>{inr(r.period_credit)}</td>
          <td className={`${num} text-ink`}>{inr(dr(r.closing))}</td>
          <td className={`${num} text-ink`}>{inr(cr(r.closing))}</td>
        </tr>
      ))}
      <tr className="border-b border-line-strong bg-surface-sunken/60 text-xs font-semibold">
        <td className="px-4 py-2 text-ink">Subtotal — {title}</td>
        <td className={num}>{inr(sub.od)}</td><td className={num}>{inr(sub.oc)}</td>
        <td className={num}>{inr(sub.d)}</td><td className={num}>{inr(sub.c)}</td>
        <td className={num}>{inr(sub.cd)}</td><td className={num}>{inr(sub.cc)}</td>
      </tr>
    </>
  );
}
