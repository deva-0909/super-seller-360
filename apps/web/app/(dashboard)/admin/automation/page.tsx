import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { SettingToggle, JobButtons } from "./automation-controls";

export default async function AutomationPage() {
  const user = await getCurrentUser();
  const supabase = await createClient();
  const { data: access } = await supabase.rpc("my_nav_access");
  if (access && !(access as Record<string, boolean>).automation_view) {
    return <div className="px-4 md:px-8 py-8"><p className="text-sm text-ink-muted">Your role does not have access to this screen.</p></div>;
  }
  const [{ data: settings }, { data: jobs }, { data: runs }] = await Promise.all([
    supabase.from("automation_settings").select("key, value"),
    supabase.from("scheduled_jobs").select("job_key, label, description, schedule, enabled, last_run_at, last_status, last_message").order("label"),
    supabase.from("job_runs").select("job_key, started_at, status, message").order("started_at", { ascending: false }).limit(15),
  ]);
  const on = (k: string) => (settings ?? []).find((s) => s.key === k)?.value === "on";
  const canEdit = ["Super Admin", "Operations Manager", "Finance Manager"].includes(user.roleName);
  const canToggleJobs = user.roleName === "Super Admin";
  const fmt = (t: string | null) => (t ? new Date(t).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" }) : "never");

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Automation</h1>
      <p className="mt-1 text-sm text-ink-muted">What the app does by itself, and the timed jobs behind it. Anything it cannot finish shows in the Work queue.</p>

      <div className="mt-6 grid gap-3 md:grid-cols-2">
        <SettingToggle k="auto_dispatch" label="Stock out when an order ships" canEdit={canEdit} value={on("auto_dispatch")}
          help="Takes the stock out of the best-stocked warehouse as soon as an order is marked shipped. Switch off until opening stock is loaded." />
        <SettingToggle k="auto_invoice" label="Tax invoice when an order ships or is delivered" canEdit={canEdit} value={on("auto_invoice")}
          help="Posts the sales entry and numbers the invoice by itself. Each channel decides whether that happens on shipping or on delivery." />
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Timed jobs</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-sm">
          <thead><tr className="border-b border-line text-left text-xs text-ink-muted"><th className="p-3">Job</th><th className="p-3">When (UTC cron)</th><th className="p-3">Last run</th><th className="p-3">Result</th><th className="p-3" /></tr></thead>
          <tbody>
            {(jobs ?? []).map((j) => (
              <tr key={j.job_key} className="border-b border-line last:border-0 align-top">
                <td className="p-3"><p className="font-medium text-ink">{j.label}{j.enabled ? "" : " (off)"}</p><p className="text-xs text-ink-muted">{j.description}</p></td>
                <td className="p-3 font-data text-xs">{j.schedule}</td>
                <td className="p-3 text-xs">{fmt(j.last_run_at)}</td>
                <td className={`p-3 text-xs ${j.last_status === "error" ? "text-danger" : "text-ink"}`}>{j.last_status ?? "—"}{j.last_message ? ` · ${j.last_message}` : ""}</td>
                <td className="p-3"><JobButtons jobKey={j.job_key} enabled={j.enabled} canRun={canEdit} canToggle={canToggleJobs} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-2 text-xs text-ink-muted">
        The timer needs pg_cron: in Supabase open Database → Extensions, switch on pg_cron, then run <span className="font-data">select register_job_timers();</span> once in the SQL Editor.
        Without it, use Run now.
      </p>

      <h2 className="mt-8 text-sm font-semibold text-ink">Recent runs</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-xs">
        {(runs ?? []).map((r, i) => (
          <li key={i} className="flex justify-between gap-3 px-3 py-2"><span>{fmt(r.started_at)} · {r.job_key}</span><span className={r.status === "error" ? "text-danger" : "text-ink-muted"}>{r.status}{r.message ? ` · ${r.message}` : ""}</span></li>
        ))}
        {(runs ?? []).length === 0 ? <li className="px-3 py-2 text-ink-muted">No runs yet.</li> : null}
      </ul>
    </div>
  );
}
