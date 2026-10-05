export type Gate =
  | "accounting_view" | "accounting_write" | "bankcod_view" | "settlements_view" | "returns_view" | "claims_view" | "tax_view" | "gst_view"
  | "inventory_view" | "users_view" | "roles_view" | "audit_view" | "integrations_view" | "channels_view" | "warehouses_view" | "uploads" | "automation_view" | "connectors_manage" | "purchasing_view" | "payroll_view" | "journal_review";

export type NavItem = {
  label: string;
  href?: string;
  status: "live" | "soon";
  /**
   * Which part of the app this screen belongs to. The flag comes from my_nav_access() in the database, which is computed from the same
   * has_*() helpers the row-level security uses, so the menu shows a screen only when the signed-in role (or the role being previewed)
   * can actually use it. Left out = visible to everyone.
   */
  gate?: Gate;
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
      { label: "Work Queue", href: "/work-queue", status: "live" },
      { label: "Ask a Question", href: "/ask", status: "live" },
      { label: "Dashboards", href: "/dashboard", status: "live" },
      { label: "Business Insights", href: "/insights", status: "live" },
      { label: "Orders", href: "/orders", status: "live" },
      { label: "Excel Uploads", href: "/imports", status: "live", gate: "uploads" },
      { label: "Inventory", href: "/inventory", status: "live", gate: "inventory_view" },
      { label: "Returns", href: "/returns", status: "live", gate: "returns_view" },
      { label: "RTO", href: "/rto", status: "live", gate: "returns_view" },
      { label: "Settlements", href: "/settlements", status: "live", gate: "settlements_view" },
      { label: "Bank / COD", href: "/bank", status: "live", gate: "bankcod_view" },
      { label: "COD Collections", href: "/cod", status: "live", gate: "bankcod_view" },
      { label: "Expense Claims", href: "/expenses", status: "live" },
      { label: "Claims", href: "/claims", status: "live", gate: "claims_view" },
      { label: "Tax", href: "/tax", status: "live", gate: "tax_view" },
      { label: "GST Returns", href: "/gst", status: "live", gate: "gst_view" },
      { label: "Accounting", href: "/accounting/ledgers", status: "live", gate: "accounting_view" },
      { label: "Purchase Orders", href: "/purchases/orders", status: "live", gate: "purchasing_view" },
      { label: "Purchases", href: "/purchases/bills", status: "live", gate: "accounting_view" },
      { label: "Opening Balances", href: "/accounting/opening-balances", status: "live", gate: "accounting_view" },
      { label: "Fixed Assets", href: "/accounting/assets", status: "live", gate: "accounting_view" },
      { label: "Statutory Calendar", href: "/accounting/statutory", status: "live", gate: "accounting_view" },
      { label: "Payroll", href: "/payroll", status: "live", gate: "payroll_view" },
      { label: "Journal Entries", href: "/accounting/journal", status: "live", gate: "accounting_view" },
      { label: "Journal Review", href: "/accounting/journal/review", status: "live", gate: "journal_review" },
      { label: "Cash Settlement", href: "/accounting/cash-settlement", status: "live", gate: "bankcod_view" },
      { label: "Rule Book", href: "/accounting/rule-book", status: "live", gate: "accounting_view" },
      { label: "Trial Balance", href: "/accounting/trial-balance", status: "live", gate: "accounting_view" },
      { label: "Day Book", href: "/accounting/day-book", status: "live", gate: "accounting_view" },
      { label: "Profit & Loss", href: "/accounting/profit-and-loss", status: "live", gate: "accounting_view" },
      { label: "Balance Sheet", href: "/accounting/balance-sheet", status: "live", gate: "accounting_view" },
      { label: "Cash Flow", href: "/accounting/cash-flow", status: "live", gate: "bankcod_view" },
      { label: "Periods", href: "/accounting/periods", status: "live", gate: "accounting_view" },
      { label: "Reports", status: "soon", gate: "accounting_view" },
    ],
  },
  {
    label: "Administration",
    items: [
      { label: "Users", href: "/admin/users", status: "live", gate: "users_view" },
      { label: "Roles", href: "/admin/roles", status: "live", gate: "roles_view" },
      { label: "Channels", href: "/admin/channels", status: "live", gate: "channels_view" },
      { label: "Products", href: "/admin/products", status: "live" },
      { label: "Listing Map", href: "/admin/channels/listing-map", status: "live", gate: "channels_view" },
      { label: "Warehouses", href: "/admin/warehouses", status: "live", gate: "warehouses_view" },
      { label: "Permissions", href: "/admin/permissions", status: "live", gate: "roles_view" },
      { label: "Connection Centre", href: "/admin/connectors", status: "live", gate: "connectors_manage" },
      { label: "Integrations", href: "/admin/integrations", status: "live", gate: "integrations_view" },
      { label: "Automation", href: "/admin/automation", status: "live", gate: "automation_view" },
      { label: "Audit Trail", href: "/admin/audit-trail", status: "live", gate: "audit_view" },
    ],
  },
  {
    label: "Settings",
    items: [
      { label: "Sessions", href: "/settings/sessions", status: "live" },
      { label: "Security (2-step)", href: "/settings/security", status: "live" },
    ],
  },
];
