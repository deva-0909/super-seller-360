export type NavItem = {
  label: string;
  href?: string;
  status: "live" | "soon";
  /**
   * Roles that would see zero rows if they opened this screen — matches
   * the exact has_*_view() RLS function behind each screen's main query,
   * not a looser "Admin tier" guess. Screens with no restriction here
   * (Users, Roles, Channels, Products, Warehouses, Permissions,
   * Integrations, Audit Trail) are intentionally omitted: every role sees
   * at least some real rows there (even if just their own), so hiding them
   * would misrepresent genuine "limited" access as "zero" access.
   */
  hiddenFor?: string[];
};

export type NavSection = {
  label: string;
  items: NavItem[];
};

const NO_INVENTORY_RETURNS_CLAIMS = ["Accountant", "Tax Manager"]; // has_returns_view / has_claims_view
const NO_SETTLEMENTS_BANKCOD = ["Warehouse Manager"]; // has_settlements_view / has_bankcod_view
const NO_ACCOUNTING = ["Warehouse Manager", "Marketplace Manager"]; // has_accounting_view
const NO_TAX = ["Warehouse Manager", "Claims Manager"]; // has_tax_view

// Mirrors the Screen Master module list. Phase 1 ships Admin + Settings;
// everything else lights up module-by-module as later phases land, so the
// nav communicates the roadmap instead of linking to screens that don't exist yet.
export const NAV_SECTIONS: NavSection[] = [
  {
    label: "Workspace",
    items: [
      { label: "Dashboards", href: "/dashboard", status: "live" },
      { label: "Orders", href: "/orders", status: "live" },
      { label: "Inventory", href: "/inventory", status: "live", hiddenFor: NO_INVENTORY_RETURNS_CLAIMS },
      { label: "Returns", href: "/returns", status: "live", hiddenFor: NO_INVENTORY_RETURNS_CLAIMS },
      { label: "RTO", href: "/rto", status: "live", hiddenFor: NO_INVENTORY_RETURNS_CLAIMS },
      { label: "Settlements", href: "/settlements", status: "live", hiddenFor: NO_SETTLEMENTS_BANKCOD },
      { label: "Bank / COD", href: "/bank", status: "live", hiddenFor: NO_SETTLEMENTS_BANKCOD },
      { label: "COD Collections", href: "/cod", status: "live", hiddenFor: NO_SETTLEMENTS_BANKCOD },
      { label: "Claims", href: "/claims", status: "live", hiddenFor: NO_INVENTORY_RETURNS_CLAIMS },
      { label: "Tax", href: "/tax", status: "live", hiddenFor: NO_TAX },
      { label: "Accounting", href: "/accounting/ledgers", status: "live", hiddenFor: NO_ACCOUNTING },
      { label: "Profit & Loss", href: "/accounting/profit-and-loss", status: "live", hiddenFor: NO_ACCOUNTING },
      { label: "Balance Sheet", href: "/accounting/balance-sheet", status: "live", hiddenFor: NO_ACCOUNTING },
      { label: "Cash Flow", href: "/accounting/cash-flow", status: "live", hiddenFor: NO_SETTLEMENTS_BANKCOD },
      { label: "Periods", href: "/accounting/periods", status: "live", hiddenFor: NO_ACCOUNTING },
      { label: "Reports", status: "soon" },
    ],
  },
  {
    label: "Administration",
    items: [
      { label: "Users", href: "/admin/users", status: "live" },
      { label: "Roles", href: "/admin/roles", status: "live" },
      { label: "Channels", href: "/admin/channels", status: "live" },
      { label: "Products", href: "/admin/products", status: "live" },
      { label: "Warehouses", href: "/admin/warehouses", status: "live" },
      { label: "Permissions", href: "/admin/permissions", status: "live" },
      { label: "Integrations", href: "/admin/integrations", status: "live" },
      { label: "Audit Trail", href: "/admin/audit-trail", status: "live" },
    ],
  },
  {
    label: "Settings",
    items: [
      { label: "Sessions", href: "/settings/sessions", status: "live" },
    ],
  },
];
