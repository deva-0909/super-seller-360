"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useMemo, useSyncExternalStore } from "react";
import { NAV_SECTIONS } from "@/lib/nav-sections";

const KEY = "nav-open-sections";
const EVT = "nav-open-change";
let memory: string | null = null; // used when the browser will not let us store anything
function read(): string {
  if (memory !== null) return memory;
  try { return localStorage.getItem(KEY) ?? "[]"; } catch { return "[]"; }
}
function save(next: string[]) {
  memory = JSON.stringify(next);
  try { localStorage.setItem(KEY, memory); } catch { /* private mode: lasts until the page reloads */ }
  window.dispatchEvent(new Event(EVT));
}
function subscribe(cb: () => void) {
  window.addEventListener(EVT, cb);
  window.addEventListener("storage", cb);
  return () => { window.removeEventListener(EVT, cb); window.removeEventListener("storage", cb); };
}

export function Sidebar({ access, onNavigate }: { access: Record<string, boolean> | null; onNavigate?: () => void }) {
  const pathname = usePathname();
  // Sections are folded away; the one holding the page you are on is always open, and what you open stays open on this device.
  const raw = useSyncExternalStore(subscribe, read, () => "[]");
  const opened = useMemo<string[]>(() => { try { return JSON.parse(raw) as string[]; } catch { return []; } }, [raw]);
  function toggle(label: string) {
    const next = opened.includes(label) ? opened.filter((x) => x !== label) : [...opened, label];
    save(next);
  }

  return (
    <nav className="flex h-full w-full flex-col gap-1 overflow-y-auto bg-sidebar-bg px-4 py-4">
      {NAV_SECTIONS.map((section) => {
        const visibleItems = section.items.filter(
          (item) => !item.gate || access === null || access[item.gate] === true,
        );
        if (!visibleItems.length) return null;
        // the most specific link wins, so /inventory does not light up while you are on /inventory/pack
        const hrefs = visibleItems.map((i) => i.href).filter((h): h is string => !!h);
        const best = NAV_SECTIONS.flatMap((s) => s.items).map((i) => i.href).filter((h): h is string => !!h && pathname.startsWith(h)).sort((a, b) => b.length - a.length)[0];
        const hasActive = !!best && hrefs.includes(best);
        const isOpen = hasActive || opened.includes(section.label);

        return (
          <div key={section.label}>
            <button
              type="button"
              onClick={() => toggle(section.label)}
              aria-expanded={isOpen}
              className="flex w-full items-center justify-between rounded-lg px-2 py-2 text-xs font-semibold uppercase tracking-wide text-sidebar-text-muted hover:bg-white/5 hover:text-sidebar-text-active"
            >
              <span>{section.label}</span>
              <span aria-hidden="true" className={`text-[10px] transition-transform ${isOpen ? "rotate-90" : ""}`}>▶</span>
            </button>
            {isOpen ? (
              <ul className="mb-2 mt-1 flex flex-col gap-0.5">
                {visibleItems.map((item) => {
                  const active = !!item.href && item.href === best;
                  if (item.status === "soon" || !item.href) {
                    return (
                      <li key={item.label}>
                        <span className="flex items-center justify-between rounded-lg px-2 py-1.5 text-sm text-sidebar-text-muted">
                          {item.label}
                          <span className="text-xs">soon</span>
                        </span>
                      </li>
                    );
                  }
                  return (
                    <li key={item.label}>
                      <Link
                        href={item.href}
                        onClick={onNavigate}
                        className={`block rounded-lg px-2 py-2.5 text-sm md:py-1.5 transition-colors ${
                          active
                            ? "bg-sidebar-bg-active font-medium text-sidebar-text-active"
                            : "text-sidebar-text hover:bg-white/5 hover:text-sidebar-text-active"
                        }`}
                      >
                        {item.label}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            ) : null}
          </div>
        );
      })}
    </nav>
  );
}
