import { PurchasesTabs } from "@/components/purchases/bits";

// Each section below carries its own access check (Purchase Orders and Re-order need the purchasing role,
// bills / payments / TDS need the accounting role), so a role that may see one is not blocked by the other.
export default function PurchasesLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <PurchasesTabs />
      {children}
    </div>
  );
}
