"use client";

import { createContext, useContext, useSyncExternalStore } from "react";

// A list on the left and an "add / log" form on the right. The form can be folded away so the list gets the full width.
// The choice is remembered in this browser (one setting for every screen); if the browser blocks storage it still works for the visit.
const KEY = "ss-side-collapsed";
const listeners = new Set<() => void>();
let mem: boolean | null = null;

function subscribe(cb: () => void) {
  listeners.add(cb);
  window.addEventListener("storage", cb);
  return () => { listeners.delete(cb); window.removeEventListener("storage", cb); };
}
function read(): boolean {
  if (mem !== null) return mem;
  try { return window.localStorage.getItem(KEY) === "1"; } catch { return false; }
}
function write(v: boolean) {
  mem = v;
  try { window.localStorage.setItem(KEY, v ? "1" : "0"); } catch { /* storage blocked: keep it in memory only */ }
  listeners.forEach((f) => f());
}

const Ctx = createContext<{ collapsed: boolean; toggle: () => void }>({ collapsed: false, toggle: () => {} });

export function SplitLayout({ children }: { children: React.ReactNode }) {
  const collapsed = useSyncExternalStore(subscribe, read, () => false);
  return (
    <Ctx.Provider value={{ collapsed, toggle: () => write(!collapsed) }}>
      <div className={`mt-6 grid grid-cols-1 gap-6 ${collapsed ? "lg:grid-cols-[1fr_auto]" : "lg:grid-cols-[1fr_320px]"}`}>{children}</div>
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
