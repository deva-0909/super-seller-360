"use client";

import { createContext, useContext, useState } from "react";
import { Sidebar } from "./sidebar";

const NavContext = createContext<{ open: boolean; setOpen: (v: boolean) => void }>({ open: false, setOpen: () => {} });

/** The hamburger shown in the top bar on phones. */
export function MenuButton() {
  const { open, setOpen } = useContext(NavContext);
  return (
    <button
      type="button"
      onClick={() => setOpen(!open)}
      aria-label={open ? "Close menu" : "Open menu"}
      aria-expanded={open}
      className="mr-2 flex h-10 w-10 items-center justify-center rounded-lg border border-line text-ink hover:bg-surface-sunken md:hidden"
    >
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
        {open ? <path d="M4 4l12 12M16 4L4 16" /> : <path d="M3 5h14M3 10h14M3 15h14" />}
      </svg>
    </button>
  );
}

/**
 * The page frame. On a phone the menu is a drawer that slides in over the page (closes when a link is tapped or the
 * dark area is tapped); from tablet width up it is the fixed side column as before.
 */
export function AppShell({ topbar, reminder, access, children }: { topbar: React.ReactNode; reminder: React.ReactNode; access: Record<string, boolean> | null; children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <NavContext.Provider value={{ open, setOpen }}>
      <div className="flex h-dvh flex-col">
        {topbar}
        {reminder}
        <div className="relative flex min-h-0 flex-1 overflow-hidden">
          {open ? <div className="fixed inset-0 top-14 z-30 bg-black/40 md:hidden" onClick={() => setOpen(false)} aria-hidden="true" /> : null}
          <div
            className={`fixed bottom-0 left-0 top-14 z-40 w-64 max-w-[85vw] transition-transform duration-200 md:static md:z-auto md:w-60 md:max-w-none md:shrink-0 md:translate-x-0 ${
              open ? "translate-x-0" : "-translate-x-full"
            }`}
          >
            <Sidebar access={access} onNavigate={() => setOpen(false)} />
          </div>
          <main className="min-w-0 flex-1 overflow-y-auto">{children}</main>
        </div>
      </div>
    </NavContext.Provider>
  );
}
