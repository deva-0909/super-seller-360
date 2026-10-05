"use client";

export function PrintButton() {
  return <button type="button" onClick={() => window.print()} className="h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken">Print or save as PDF</button>;
}
