// Dependency-free SVG/CSS charts so the owner screens render on the server with no client JS.

export const inr = (n: number) => `₹${Math.round(n).toLocaleString("en-IN")}`;

export const CHANNEL_COLORS = ["#2563eb", "#f59e0b", "#16a34a", "#7c3aed", "#db2777"];

/** Horizontal bar list: label, bar scaled to the max, value text. */
export function BarList({
  rows,
  color = "#2563eb",
  empty = "Nothing to show yet.",
}: {
  rows: { label: string; sublabel?: string; value: number; display: string; color?: string }[];
  color?: string;
  empty?: string;
}) {
  if (!rows.length) return <p className="py-6 text-center text-sm text-ink-muted">{empty}</p>;
  const max = Math.max(...rows.map((r) => r.value), 1);
  return (
    <ul className="flex flex-col gap-2.5">
      {rows.map((r) => (
        <li key={r.label + (r.sublabel ?? "")}>
          <div className="flex items-baseline justify-between gap-3 text-xs">
            <span className="truncate text-ink" title={r.label}>
              {r.label}
              {r.sublabel ? <span className="ml-2 font-data text-ink-faint">{r.sublabel}</span> : null}
            </span>
            <span className="font-data shrink-0 font-medium text-ink">{r.display}</span>
          </div>
          <div className="mt-1 h-2 w-full bg-surface-sunken">
            <div
              className="h-2"
              style={{ width: `${Math.max(2, (r.value / max) * 100)}%`, background: r.color ?? color }}
            />
          </div>
        </li>
      ))}
    </ul>
  );
}

/** Stacked single bar with legend: parts sum to 100%. */
export function StackBar({
  parts,
}: {
  parts: { label: string; value: number; color: string; display?: string }[];
}) {
  const total = parts.reduce((s, p) => s + p.value, 0) || 1;
  return (
    <div>
      <div className="flex h-4 w-full overflow-hidden bg-surface-sunken">
        {parts.map((p) =>
          p.value > 0 ? (
            <div key={p.label} title={`${p.label}: ${p.display ?? p.value}`} style={{ width: `${(p.value / total) * 100}%`, background: p.color }} />
          ) : null,
        )}
      </div>
      <ul className="mt-3 flex flex-wrap gap-x-5 gap-y-1.5 text-xs">
        {parts.map((p) => (
          <li key={p.label} className="flex items-center gap-1.5 text-ink-muted">
            <span className="inline-block h-2.5 w-2.5" style={{ background: p.color }} />
            {p.label}
            <span className="font-data font-medium text-ink">{p.display ?? p.value}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Multi-series line chart over a shared x axis (labels are the dates). */
export function LineChart({
  labels,
  series,
  height = 190,
}: {
  labels: string[];
  series: { name: string; color: string; values: number[] }[];
  height?: number;
}) {
  const W = 640;
  const H = height;
  const pad = { l: 44, r: 10, t: 10, b: 24 };
  const max = Math.max(...series.flatMap((s) => s.values), 1);
  const x = (i: number) => pad.l + (labels.length <= 1 ? 0 : (i / (labels.length - 1)) * (W - pad.l - pad.r));
  const y = (v: number) => pad.t + (1 - v / max) * (H - pad.t - pad.b);
  const ticks = [0, 0.5, 1].map((t) => t * max);
  const every = Math.max(1, Math.ceil(labels.length / 7));
  return (
    <div>
      <svg viewBox={`0 0 ${W} ${H}`} className="w-full" role="img" aria-label="Revenue trend by platform">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={W - pad.r} y1={y(t)} y2={y(t)} stroke="#dde3f0" strokeWidth="1" />
            <text x={pad.l - 6} y={y(t) + 4} textAnchor="end" fontSize="10" fill="#97a3bd">
              {t >= 1000 ? `${Math.round(t / 1000)}k` : Math.round(t)}
            </text>
          </g>
        ))}
        {labels.map((l, i) =>
          i % every === 0 ? (
            <text key={l} x={x(i)} y={H - 6} textAnchor="middle" fontSize="10" fill="#97a3bd">
              {l}
            </text>
          ) : null,
        )}
        {series.map((s) => (
          <polyline
            key={s.name}
            fill="none"
            stroke={s.color}
            strokeWidth="2"
            strokeLinejoin="round"
            points={s.values.map((v, i) => `${x(i)},${y(v)}`).join(" ")}
          />
        ))}
      </svg>
      <ul className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-xs text-ink-muted">
        {series.map((s) => (
          <li key={s.name} className="flex items-center gap-1.5">
            <span className="inline-block h-0.5 w-4" style={{ background: s.color, height: 3 }} />
            {s.name}
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Donut for share-of-total (revenue by platform). */
export function Donut({
  parts,
  centre,
}: {
  parts: { label: string; value: number; color: string }[];
  centre: string;
}) {
  const total = parts.reduce((s, p) => s + p.value, 0) || 1;
  const R = 52;
  const C = 2 * Math.PI * R;
  return (
    <svg viewBox="0 0 140 140" className="mx-auto h-40 w-40" role="img" aria-label="Share of revenue by platform">
      <g transform="rotate(-90 70 70)">
        {parts.map((p, i) => {
          const len = (p.value / total) * C;
          const offset = parts.slice(0, i).reduce((s2, q) => s2 + (q.value / total) * C, 0);
          return (
            <circle key={p.label} cx="70" cy="70" r={R} fill="none" stroke={p.color} strokeWidth="18"
              strokeDasharray={`${len} ${C - len}`} strokeDashoffset={-offset} />
          );
        })}
      </g>
      <text x="70" y="68" textAnchor="middle" fontSize="11" fill="#5b6b8c">Total</text>
      <text x="70" y="84" textAnchor="middle" fontSize="13" fontWeight="600" fill="#1b2a4a">{centre}</text>
    </svg>
  );
}

export function Card({ title, subtitle, children, className = "" }: { title: string; subtitle?: string; children: React.ReactNode; className?: string }) {
  return (
    <section className={`border border-line bg-surface p-5 ${className}`}>
      <h2 className="text-sm font-semibold text-ink">{title}</h2>
      {subtitle ? <p className="mt-0.5 text-xs text-ink-muted">{subtitle}</p> : null}
      <div className="mt-4">{children}</div>
    </section>
  );
}
