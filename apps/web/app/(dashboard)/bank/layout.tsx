import { BankTabs } from "./bank-tabs";

export default function BankLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="px-8 pt-6">
        <BankTabs />
      </div>
      {children}
    </div>
  );
}
