import { InputHTMLAttributes, forwardRef } from "react";

export const Field = forwardRef<
  HTMLInputElement,
  InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }
>(function Field({ label, hint, id, className, ...props }, ref) {
  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={id} className="text-sm font-medium text-ink">
        {label}
      </label>
      <input
        ref={ref}
        id={id}
        className={`h-10 border border-line bg-surface px-3 text-sm text-ink placeholder:text-ink-faint outline-none transition-colors focus:border-accent ${className ?? ""}`}
        {...props}
      />
      {hint ? <p className="text-xs text-ink-muted">{hint}</p> : null}
    </div>
  );
});
