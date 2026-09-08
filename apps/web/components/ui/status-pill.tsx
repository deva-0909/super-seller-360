type Status = "success" | "warning" | "danger" | "neutral";

const STYLES: Record<Status, string> = {
  success: "text-success bg-success-tint border-success/30",
  warning: "text-warning bg-warning-tint border-warning/30",
  danger: "text-danger bg-danger-tint border-danger/30",
  neutral: "text-neutral bg-neutral-tint border-neutral/30",
};

/**
 * Every screen in the BRD lists explicit states (Loading/Empty/Success/
 * Warning/Error/Permission denied, plus module-specific statuses like
 * Reconciled/Short Pay/Overdue). This is the one shared way to render them.
 */
export function StatusPill({
  status,
  children,
}: {
  status: Status;
  children: string;
}) {
  return (
    <span
      className={`inline-flex items-center border px-2 py-0.5 text-xs font-medium ${STYLES[status]}`}
    >
      {children}
    </span>
  );
}
