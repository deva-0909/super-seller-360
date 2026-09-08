import { ButtonHTMLAttributes } from "react";

type Variant = "primary" | "secondary";

export function Button({
  variant = "primary",
  className,
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  const base =
    "h-10 w-full text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed";
  const styles =
    variant === "primary"
      ? "bg-accent text-white hover:bg-accent-hover"
      : "border border-line bg-surface text-ink hover:bg-surface-sunken";

  return (
    <button className={`${base} ${styles} ${className ?? ""}`} {...props}>
      {children}
    </button>
  );
}
