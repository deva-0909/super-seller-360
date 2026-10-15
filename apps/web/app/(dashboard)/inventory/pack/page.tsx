import Link from "next/link";
import { PackOrder } from "./pack-order";

export default function PackPage() {
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/inventory" className="text-xs text-accent hover:underline">← Inventory</Link>
      <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Pack an order</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        Find the order, then scan the serial label on every piece that goes in the parcel. When the order ships, exactly those pieces are marked sold, and a piece that is already sold cannot be packed again. If an order shipped before it was scanned, scan the pieces that left here to complete it.
      </p>
      <div className="mt-4"><PackOrder /></div>
    </div>
  );
}
