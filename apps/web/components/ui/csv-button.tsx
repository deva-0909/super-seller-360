"use client";

import { toCsv } from "@/lib/report-utils";

/** Downloads the rows it is given as a .csv file (opens in Excel). The rows are built on the server from what is on screen. */
export function CsvButton({
  rows,
  filename,
  label = "Download Excel (CSV)",
}: {
  rows: (string | number | null | undefined)[][];
  filename: string;
  label?: string;
}) {
  function download() {
    const blob = new Blob(["﻿" + toCsv(rows)], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename.endsWith(".csv") ? filename : `${filename}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return (
    <button
      type="button"
      onClick={download}
      className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken"
    >
      {label}
    </button>
  );
}
