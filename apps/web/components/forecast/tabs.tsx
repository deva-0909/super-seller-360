import Link from "next/link";

const TABS = [["/forecast/demand", "Product demand"], ["/forecast/cash", "Cash for 13 weeks"]];

export function ForecastTabs({ active, show }: { active: string; show: { demand: boolean; cash: boolean } }) {
  return (
    <div className="mb-4 flex flex-wrap gap-2 border-b border-line pb-3 text-sm">
      {TABS.filter(([h]) => (h.endsWith("demand") ? show.demand : show.cash)).map(([href, label]) => (
        <Link key={href} href={href} className={`rounded-lg px-3 py-1.5 ${href === active ? "bg-accent text-white" : "text-ink hover:bg-surface-sunken"}`}>{label}</Link>
      ))}
    </div>
  );
}
