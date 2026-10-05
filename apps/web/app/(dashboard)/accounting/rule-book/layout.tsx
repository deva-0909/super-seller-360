import { AccessGuard } from "@/components/shell/access-guard";
import { createClient } from "@/lib/supabase/server";
import { RuleBookTabs } from "./rule-book-tabs";

export default async function RuleBookLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { count } = await supabase
    .from("journal_rule_log")
    .select("log_id", { count: "exact", head: true })
    .eq("status", "draft");

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Accounting Rule Book</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        How the app turns business events — a return received, an RTO, COD cash, a settlement, a bank line — into journal entries.
        The defaults are set the way an experienced chartered accountant would; change any of them to match your own books.
        Changes only affect <strong>future</strong> entries — posted vouchers are never rewritten.
      </p>
      <div className="mt-5">
        <RuleBookTabs reviewCount={count ?? 0} />
      </div>
      <div className="mt-6"><AccessGuard gate="books_view">{children}</AccessGuard></div>
    </div>
  );
}
