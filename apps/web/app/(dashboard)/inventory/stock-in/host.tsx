"use client";

import { useRouter } from "next/navigation";
import { StockIn } from "@/components/scan/stock-in";
import type { CatRow } from "@/lib/scan/catalog";

export function StockInHost(props: { catalog: CatRow[]; warehouses: { id: string; label: string }[]; suppliers: { id: string; label: string }[]; defaultWarehouse: string }) {
  const router = useRouter();
  return <StockIn {...props} onDone={() => router.refresh()} />;
}
