import { PurchasesTabs } from "@/components/purchases/bits";

export default function PurchasesLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <PurchasesTabs />
      {children}
    </div>
  );
}
