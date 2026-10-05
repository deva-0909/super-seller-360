import { AccessGuard } from "@/components/shell/access-guard";
import { PurchasesTabs } from "@/components/purchases/bits";

export default function PurchasesLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <PurchasesTabs />
      <AccessGuard gate="purchasing_view">{children}</AccessGuard>
    </div>
  );
}
