export type NavItem = {
  label: string;
  href?: string;
  status: "live" | "soon";
};

export type NavSection = {
  label: string;
  items: NavItem[];
};

// Mirrors the Screen Master module list. Phase 1 ships Admin + Settings;
// everything else lights up module-by-module as later phases land, so the
// nav communicates the roadmap instead of linking to screens that don't exist yet.
export const NAV_SECTIONS: NavSection[] = [
  {
    label: "Workspace",
    items: [
      { label: "Dashboards", href: "/dashboard", status: "live" },
      { label: "Orders", href: "/orders", status: "live" },
      { label: "Inventory", href: "/inventory", status: "live" },
      { label: "Returns", href: "/returns", status: "live" },
      { label: "RTO", href: "/rto", status: "live" },
      { label: "Settlements", href: "/settlements", status: "live" },
      { label: "Bank / COD", href: "/bank", status: "live" },
      { label: "COD Collections", href: "/cod", status: "live" },
      { label: "Claims", href: "/claims", status: "live" },
      { label: "Tax", href: "/tax", status: "live" },
      { label: "Accounting", href: "/accounting/ledgers", status: "live" },
      { label: "Profit & Loss", href: "/accounting/profit-and-loss", status: "live" },
      { label: "Balance Sheet", href: "/accounting/balance-sheet", status: "live" },
      { label: "Cash Flow", href: "/accounting/cash-flow", status: "live" },
      { label: "Periods", href: "/accounting/periods", status: "live" },
      { label: "Reports", status: "soon" },
    ],
  },
  {
    label: "Administration",
    items: [
      { label: "Users", href: "/admin/users", status: "live" },
      { label: "Roles", href: "/admin/roles", status: "live" },
      { label: "Channels", href: "/admin/channels", status: "live" },
      { label: "Permissions", status: "soon" },
      { label: "Integrations", status: "soon" },
      { label: "Audit Trail", status: "soon" },
    ],
  },
  {
    label: "Settings",
    items: [
      { label: "Sessions", href: "/settings/sessions", status: "live" },
    ],
  },
];
