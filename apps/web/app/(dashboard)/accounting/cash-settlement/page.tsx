import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { Proofs } from "@/components/ui/proofs";
import { RescanButton, SettingsForm, SettleForm, type LedgerOpt } from "./cash-client";

type Movement = {
  movement_id: string; voucher_no: string | null; movement_date: string; amount: number; accounted: number; declared: number;
  status: "open" | "settled" | "void"; settle_method: "auto" | "report" | null; settled_at: string | null; narration: string | null;
};
type Report = {
  report_id: string; movement_id: string; total: number; note: string | null; submitted_at: string; voucher_id: string | null;
  cash_settlement_report_lines: { kind: string; amount: number; narration: string | null; ledgers: { name: string } | null }[];
};

const inr = (n: number) => "₹" + Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const KIND: Record<string, string> = { spent: "Spent", returned_to_bank: "Returned to bank", kept_in_hand: "Kept in hand", other_recorded: "Recorded elsewhere" };
const daysAgo = (d: string) => Math.max(0, Math.floor((Date.now() - new Date(d + "T00:00:00").getTime()) / 86400000));

export default async function CashSettlementPage() {
  const supabase = await createClient();
  const [{ data: mv }, { data: rp }, { data: lg }, { data: st }, { data: canWrite }, { data: canSettings }] = await Promise.all([
    supabase.from("cash_movements").select("movement_id, voucher_no, movement_date, amount, accounted, declared, status, settle_method, settled_at, narration").neq("status", "void").order("movement_date", { ascending: false }).limit(200),
    supabase.from("cash_settlement_reports").select("report_id, movement_id, total, note, submitted_at, voucher_id, cash_settlement_report_lines(kind, amount, narration, ledgers(name))").order("submitted_at", { ascending: false }).limit(200),
    supabase.from("ledgers").select("ledger_id, name, account_groups(name)").eq("status", "active").order("name"),
    supabase.from("cash_settings").select("remind_minutes, mail_repeat_hours, tolerance, extra_recipients").eq("id", 1).maybeSingle(),
    supabase.rpc("has_bankcod_write"),
    supabase.rpc("has_rulebook_edit"),
  ]);
  const movements = (mv ?? []) as unknown as Movement[];
  const reports = new Map<string, Report>();
  for (const r of (rp ?? []) as unknown as Report[]) if (!reports.has(r.movement_id)) reports.set(r.movement_id, r);
  const ledgers: LedgerOpt[] = ((lg ?? []) as unknown as { ledger_id: string; name: string; account_groups: { name: string } | null }[])
    .filter((l) => !["Cash-in-Hand", "Bank Accounts"].includes(l.account_groups?.name ?? ""))
    .map((l) => ({ ledger_id: l.ledger_id, name: l.name }));

  const open = movements.filter((m) => m.status === "open");
  const settled = movements.filter((m) => m.status === "settled");
  const openTotal = open.reduce((s, m) => s + (Number(m.amount) - Number(m.accounted) - Number(m.declared)), 0);
  const write = canWrite === true;

  return (
    <div className="px-4 md:px-8 py-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-ink">Cash settlement</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            Whenever money moves from the bank into cash, it stays on this list — with a red warning on every screen and an e-mail to the owner —
            until the cash is accounted for. Recording cash spending in the books reduces it automatically; or submit a settlement report here.
          </p>
        </div>
        {write ? <RescanButton /> : null}
      </div>

      <div className="mt-5 grid grid-cols-2 gap-4 md:grid-cols-3">
        <div className="border border-line bg-surface p-4"><p className="text-xs text-ink-muted">Open items</p><p className={`mt-1 font-data text-xl font-semibold ${open.length ? "text-danger" : "text-success"}`}>{open.length}</p></div>
        <div className="border border-line bg-surface p-4"><p className="text-xs text-ink-muted">Still to account for</p><p className={`mt-1 font-data text-xl font-semibold ${open.length ? "text-danger" : "text-ink"}`}>{inr(openTotal)}</p></div>
        <div className="border border-line bg-surface p-4"><p className="text-xs text-ink-muted">Settled</p><p className="mt-1 font-data text-xl font-semibold text-ink">{settled.length}</p></div>
      </div>

      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">Waiting to be settled</h2>
        {open.length === 0 ? <p className="mt-2 border border-line bg-surface p-4 text-sm text-ink-muted">Nothing pending. Every cash withdrawal is accounted for.</p> : null}
        <div className="mt-2 space-y-3">
          {open.map((m) => {
            const left = Number(m.amount) - Number(m.accounted) - Number(m.declared);
            return (
              <div key={m.movement_id} className="border border-danger/30 bg-surface p-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-sm font-semibold text-ink">{m.voucher_no ?? "Cash withdrawal"}</span>
                      <StatusPill status="danger">{`Open ${daysAgo(m.movement_date)}d`}</StatusPill>
                    </div>
                    <p className="mt-1 text-xs text-ink-muted">{m.movement_date} · {m.narration ?? "Bank to cash"}</p>
                    <p className="mt-1 text-xs text-ink-muted">Withdrawn {inr(Number(m.amount))} · cash spending booked {inr(Number(m.accounted))} · <span className="font-semibold text-danger">still to account for {inr(left)}</span></p>
                  </div>
                </div>
                {write ? (
                  <div className="mt-3"><SettleForm movementId={m.movement_id} openAmount={Math.round(left * 100) / 100} ledgers={ledgers} /></div>
                ) : <p className="mt-2 text-xs text-ink-muted">Only a Super Admin, Finance Manager or Accountant can submit the settlement report.</p>}
              </div>
            );
          })}
        </div>
      </section>

      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">Settled</h2>
        {settled.length === 0 ? <p className="mt-2 text-sm text-ink-muted">No settled items yet.</p> : (
          <div className="mt-2 border border-line bg-surface">
            {settled.map((m, i) => {
              const r = reports.get(m.movement_id);
              return (
                <div key={m.movement_id} className={`px-4 py-3 ${i ? "border-t border-line" : ""}`}>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-semibold text-ink">{m.voucher_no ?? "Cash withdrawal"}</span>
                    <span className="font-data text-sm text-ink">{inr(Number(m.amount))}</span>
                    <StatusPill status="success">{m.settle_method === "report" ? "Report submitted" : "Cash entries booked"}</StatusPill>
                    <span className="text-xs text-ink-muted">{m.movement_date}{m.settled_at ? ` → settled ${m.settled_at.slice(0, 10)}` : ""}</span>
                  </div>
                  {r ? (
                    <div className="mt-1 text-xs text-ink-muted">
                      {r.cash_settlement_report_lines.map((l, k) => (
                        <p key={k}>{KIND[l.kind] ?? l.kind} {inr(Number(l.amount))}{l.ledgers?.name ? ` on ${l.ledgers.name}` : ""}{l.narration ? ` — ${l.narration}` : ""}</p>
                      ))}
                      {r.note ? <p className="italic">“{r.note}”</p> : null}
                      <div className="mt-2"><Proofs entityType="cash_settlement_report" entityId={r.report_id} readOnly label="Proofs" /></div>
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        )}
      </section>

      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">Reminder settings</h2>
        <div className="mt-2 border border-line bg-surface p-4">
          <SettingsForm
            remind={st?.remind_minutes ?? 30} repeat={st?.mail_repeat_hours ?? 24} tolerance={Number(st?.tolerance ?? 1)} extra={st?.extra_recipients ?? ""}
            canEdit={canSettings === true}
          />
          <p className="mt-4 border-t border-line pt-3 text-xs text-ink-muted">
            E-mail needs a one-time setup (an e-mail service key and a 15-minute schedule) — the steps are in the README under “Cash settlement”.
            The on-screen warning works without it.
          </p>
        </div>
      </section>
    </div>
  );
}
