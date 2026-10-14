"use client";

import { createContext, useContext, useSyncExternalStore } from "react";

// A list on the left and an "add / log" form on the right. The form can be folded away so the list gets the full width.
// The choice is remembered in this browser (one setting for every screen); if the browser blocks storage it still works for the visit.
const DEFAULT_KEY = "ss-side-collapsed";
const listeners = new Set<() => void>();
const mem = new Map<string, boolean>();

function subscribe(cb: () => void) {
  listeners.add(cb);
  window.addEventListener("storage", cb);
  return () => { listeners.delete(cb); window.removeEventListener("storage", cb); };
}
function read(key: string): boolean {
  const m = mem.get(key);
  if (m !== undefined) return m;
  try { return window.localStorage.getItem(key) === "1"; } catch { return false; }
}
function write(key: string, v: boolean) {
  mem.set(key, v);
  try { window.localStorage.setItem(key, v ? "1" : "0"); } catch { /* storage blocked: keep it in memory only */ }
  listeners.forEach((f) => f());
}

const Ctx = createContext<{ collapsed: boolean; toggle: () => void }>({ collapsed: false, toggle: () => {} });

/** Pass `open` / `closed` (full Tailwind class names) for layouts other than the usual list + 320px form. `memory` keeps a screen's choice separate. */
export function SplitLayout({
  children, open = "lg:grid-cols-[1fr_320px]", closed = "lg:grid-cols-[1fr_auto]", mt = "mt-6", memory = DEFAULT_KEY,
}: { children: React.ReactNode; open?: string; closed?: string; mt?: string; memory?: string }) {
  const collapsed = useSyncExternalStore(subscribe, () => read(memory), () => false);
  return (
    <Ctx.Provider value={{ collapsed, toggle: () => write(memory, !collapsed) }}>
      <div className={`${mt} grid grid-cols-1 gap-6 ${collapsed ? closed : open}`}>{children}</div>
    </Ctx.Provider>
  );
}

export function SidePanel({ children, label = "Show form" }: { children: React.ReactNode; label?: string }) {
  const { collapsed, toggle } = useContext(Ctx);
  if (collapsed) {
    return (
      <button
        type="button"
        onClick={toggle}
        aria-expanded={false}
        className="h-fit self-start border border-line bg-surface px-3 py-2 text-xs font-semibold text-accent hover:bg-surface-sunken"
      >
        ◂ {label}
      </button>
    );
  }
  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={toggle}
        aria-expanded
        className="self-end text-xs font-medium text-ink-muted hover:text-ink hover:underline"
      >
        Hide panel ▸
      </button>
      {children}
    </div>
  );
}
