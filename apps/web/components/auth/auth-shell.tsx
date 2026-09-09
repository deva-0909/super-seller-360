import { ReactNode } from "react";

/**
 * Shared frame for every Authentication-module screen (AUTH-001..005).
 * The colorful "S" badge matches the Topbar's brand mark used everywhere
 * once signed in, so the visual identity is consistent before and after login.
 */
export function AuthShell({
  title,
  description,
  children,
  footer,
}: {
  title: string;
  description?: string;
  children: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-canvas px-6 py-12">
      <div className="w-full max-w-sm">
        <Wordmark />

        <div className="mt-8 border border-line bg-surface p-8">
          <h1 className="text-xl font-semibold tracking-tight text-ink">
            {title}
          </h1>
          {description ? (
            <p className="mt-2 text-sm leading-relaxed text-ink-muted">
              {description}
            </p>
          ) : null}

          <div className="mt-6">{children}</div>
        </div>

        {footer ? (
          <p className="mt-6 text-center text-sm text-ink-muted">{footer}</p>
        ) : null}
      </div>
    </div>
  );
}

function Wordmark() {
  return (
    <div className="flex flex-col items-center gap-3">
      <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-accent text-lg font-bold text-white shadow-sm">
        S
      </span>
      <div className="flex items-baseline gap-2">
        <span className="text-lg font-semibold tracking-tight text-ink">
          Super Seller
        </span>
        <span className="font-data text-sm font-semibold text-accent">360°</span>
      </div>
    </div>
  );
}
