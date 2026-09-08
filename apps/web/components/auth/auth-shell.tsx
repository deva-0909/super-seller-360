import { ReactNode } from "react";

/**
 * Shared frame for every Authentication-module screen (AUTH-001..005).
 * Deliberately plain: a ledger-rule mark instead of an illustration,
 * a flat bordered panel instead of a shadowed card.
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
    <div className="flex min-h-screen flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm">
        <Wordmark />

        <div className="mt-10 border border-line bg-surface p-8">
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
      <div className="flex items-baseline gap-2">
        <span className="text-lg font-semibold tracking-tight text-ink">
          Super Seller
        </span>
        <span className="font-data text-sm text-accent">360°</span>
      </div>
      {/* Ledger-rule motif: the one distinctive visual anchor on this screen */}
      <div className="flex w-24 items-center gap-[3px]">
        <div className="h-px flex-1 bg-line-strong" />
        <div className="h-px flex-1 bg-line-strong" />
        <div className="h-px flex-1 bg-line-strong" />
        <div className="h-px flex-1 bg-accent" />
      </div>
    </div>
  );
}
