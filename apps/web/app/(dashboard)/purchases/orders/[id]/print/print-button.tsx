"use client";

export function PrintButton() {
  return <button className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white" onClick={() => window.print()}>Print / save as PDF</button>;
}
