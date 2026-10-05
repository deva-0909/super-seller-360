"use client";

/** Opens the browser's print dialog (choose "Save as PDF" there). */
export function PrintButton({ label = "Print / PDF" }: { label?: string }) {
  return (
    <button
      type="button"
      onClick={() => window.print()}
      className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken print:hidden"
    >
      {label}
    </button>
  );
}
