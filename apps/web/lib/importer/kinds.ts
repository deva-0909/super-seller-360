/**
 * The uploads that plug into the shared importer. Each one is described here (headings, sample row, drop-down lists, who may use it);
 * the checking and saving of the rows is done in the database (import_run, migration 0067) so the preview always matches what the import does.
 */
export type ColType = "text" | "number" | "date";

export type Column = {
  key: string;            // the name the database function reads
  heading: string;        // what the operator sees in the Excel template
  required?: boolean;
  type?: ColType;         // text keeps long numbers (barcodes, ids) from being turned into 8.9E+12
  sample?: string;
  hint?: string;
  list?: string[];        // fixed drop-down values
  listFrom?: "warehouses" | "channels" | "ledgers"; // drop-down filled from the database when the template is downloaded
  aliases?: string[];     // other headings that are accepted (what portals call the same thing)
};

export type Option = "channel" | "financial_year";

export type KindConfig = {
  kind: string;
  title: string;
  intro: string;
  roles: string[];        // for display only; the database decides (import_can)
  backHref: string;
  backLabel: string;
  columns: Column[];
  option?: Option;
  notes: string[];
};

const GST_SLABS = ["0", "0.25", "3", "5", "12", "18", "28", "40"];

export const KINDS: Record<string, KindConfig> = {
  products: {
    kind: "products",
    title: "Upload the SKU master",
    intro: "Add or update many products at once: size, colour, barcode, brand, HSN, GST %, cost and packing cost.",
    roles: ["Super Admin", "Operations Manager"],
    backHref: "/admin/products", backLabel: "Products",
    columns: [
      { key: "sku", heading: "SKU", required: true, type: "text", sample: "TEE-BLK-M", hint: "Our own SKU. This is what a re-upload matches on." },
      { key: "name", heading: "Name", required: true, type: "text", sample: "Classic Crew T-Shirt - Black - M", hint: "Required for a new SKU; leave blank to keep the current name." },
      { key: "size", heading: "Size", type: "text", sample: "M" },
      { key: "colour", heading: "Colour", type: "text", sample: "Black", aliases: ["Color"] },
      { key: "barcode", heading: "Barcode", type: "text", sample: "8901234567890", hint: "Format this column as Text so Excel keeps every digit." },
      { key: "brand", heading: "Brand", type: "text", sample: "Surat Basics" },
      { key: "category", heading: "Category", type: "text", sample: "T-Shirts" },
      { key: "hsn", heading: "HSN", type: "text", sample: "610910", hint: "4, 6 or 8 digits." },
      { key: "gst_rate", heading: "GST %", list: GST_SLABS, sample: "5", aliases: ["GST Rate", "GST"] },
      { key: "cost_price", heading: "Cost price", type: "number", sample: "120" },
      { key: "packing_cost", heading: "Packing cost", type: "number", sample: "8", aliases: ["Packaging cost"] },
      { key: "status", heading: "Status", list: ["active", "inactive", "discontinued"], sample: "active" },
    ],
    notes: [
      "A blank cell keeps whatever is already saved. It never clears a value.",
      "Uploading the same SKU again updates that product; it never adds a second one.",
      "Barcodes must be unique across products.",
    ],
  },
  opening_stock: {
    kind: "opening_stock",
    title: "Upload opening stock",
    intro: "The stock you hold on day one, per SKU and warehouse, from your physical count sheet.",
    roles: ["Super Admin", "Operations Manager", "Warehouse Manager"],
    backHref: "/inventory", backLabel: "Inventory",
    columns: [
      { key: "sku", heading: "SKU", required: true, type: "text", sample: "TEE-BLK-M" },
      { key: "warehouse", heading: "Warehouse", required: true, type: "text", listFrom: "warehouses", sample: "Surat Main Warehouse" },
      { key: "quantity", heading: "Quantity", required: true, type: "number", sample: "120", aliases: ["Qty", "Opening stock"] },
    ],
    notes: [
      "Use this once at go-live. If you upload a corrected file later, only the difference is posted.",
      "A SKU that already has sales or returns in that warehouse is rejected: use Stock count for corrections.",
      "A Warehouse Manager can only load their own warehouses.",
    ],
  },
  stock_count: {
    kind: "stock_count",
    title: "Upload a stock count",
    intro: "Counted quantity per SKU and warehouse. The difference from the system is posted as a stock adjustment.",
    roles: ["Super Admin", "Operations Manager", "Warehouse Manager"],
    backHref: "/inventory", backLabel: "Inventory",
    columns: [
      { key: "sku", heading: "SKU", required: true, type: "text", sample: "TEE-BLK-M" },
      { key: "warehouse", heading: "Warehouse", required: true, type: "text", listFrom: "warehouses", sample: "Surat Main Warehouse" },
      { key: "counted_quantity", heading: "Counted quantity", required: true, type: "number", sample: "118", aliases: ["Counted", "Count", "Physical stock"] },
    ],
    notes: [
      "Enter what you counted, not the difference. Uploading the same count again changes nothing.",
      "A large gap from the system quantity is flagged so you can recount before importing.",
    ],
  },
  listing_map: {
    kind: "listing_map",
    title: "Upload the marketplace listing map",
    intro: "Links your SKU to each marketplace's own SKU and listing id (ASIN, FSN, style id) so orders tie back to your products.",
    roles: ["Super Admin", "Operations Manager", "Marketplace Manager"],
    backHref: "/admin/channels/listing-map", backLabel: "Listing map",
    columns: [
      { key: "channel", heading: "Channel", required: true, type: "text", listFrom: "channels", sample: "Amazon - Seller Central" },
      { key: "sku", heading: "Our SKU", required: true, type: "text", sample: "TEE-BLK-M", aliases: ["SKU"] },
      { key: "listing_id", heading: "Listing id", required: true, type: "text", sample: "B0ABC12345", hint: "ASIN, FSN or style id.", aliases: ["ASIN", "FSN", "Style id", "Listing ID"] },
      { key: "channel_sku", heading: "Channel SKU", type: "text", sample: "AMZ-TEE-BLK-M", aliases: ["Seller SKU", "Marketplace SKU"] },
      { key: "status", heading: "Status", list: ["active", "inactive"], sample: "active" },
    ],
    notes: [
      "Rows are matched on channel + listing id. A corrected file updates the listing; it never adds it twice.",
      "A Marketplace Manager can only load channels they are assigned to.",
    ],
  },
  ledger_opening: {
    kind: "ledger_opening",
    title: "Upload ledger opening balances",
    intro: "Opening balances from your Tally trial balance, one row per ledger with a debit or a credit amount.",
    roles: ["Super Admin", "Finance Manager", "Accountant"],
    backHref: "/accounting/opening-balances", backLabel: "Opening balances",
    option: "financial_year",
    columns: [
      { key: "ledger", heading: "Ledger", required: true, type: "text", listFrom: "ledgers", sample: "Cash in Hand", aliases: ["Particulars", "Ledger name", "Account"] },
      { key: "debit", heading: "Debit", type: "number", sample: "50000", aliases: ["Dr", "Debit amount"] },
      { key: "credit", heading: "Credit", type: "number", sample: "", aliases: ["Cr", "Credit amount"] },
    ],
    notes: [
      "Total debits must equal total credits. The whole file is loaded together or not at all.",
      "Supplier balances go in under Purchases > Bills > Opening balances, so 'Sundry Creditors' is not accepted here.",
      "Ledger names must match the ones in Accounting > Ledgers. Create a missing ledger first.",
    ],
  },
  settlement: {
    kind: "settlement",
    title: "Upload a marketplace settlement report",
    intro: "The portal's payout report with one row per order and fee. The app builds the settlement, checks every fee against the agreed rate and flags overcharges.",
    roles: ["Super Admin", "Finance Manager", "Accountant"],
    backHref: "/settlements", backLabel: "Settlements",
    option: "channel",
    columns: [
      { key: "settlement_id", heading: "Settlement id", required: true, type: "text", sample: "ST-2026-10-01", aliases: ["settlement_id", "Payout id", "Settlement ID", "Payment id"] },
      { key: "period_start", heading: "Period start", type: "date", sample: "2026-09-16", aliases: ["From"] },
      { key: "period_end", heading: "Period end", type: "date", sample: "2026-09-30", aliases: ["To"] },
      { key: "order_id", heading: "Order id", type: "text", sample: "402-1234567-8901234", aliases: ["Order ID", "order_id", "Order number"] },
      { key: "fee_type", heading: "Type", required: true, list: ["order_value", "commission", "shipping", "gateway_fee", "tax", "refund", "other"], sample: "commission", aliases: ["Fee type", "Charge type"] },
      { key: "amount", heading: "Amount", required: true, type: "number", sample: "100", hint: "Always positive. Fees are what the marketplace kept.", aliases: ["Value"] },
      { key: "tax_amount", heading: "GST on the fee", type: "number", sample: "18", aliases: ["GST", "Tax"] },
    ],
    notes: [
      "order_value rows are what the marketplace collected for the order. Every other row is something it kept (commission, shipping, gateway_fee, tax, refund, other).",
      "GST charged on a fee goes in the GST column of that fee row, not on a separate row.",
      "A settlement is saved only if all its rows are fine. A settlement that is already uploaded is left as it is.",
      "Set the agreed rates under Settlements > Fee check and every fee line is compared with them.",
    ],
  },
  orders: {
    kind: "orders",
    title: "Import orders",
    intro: "Marketplace or website orders from the portal's order report. One row per line item.",
    roles: ["Super Admin", "Operations Manager", "Marketplace Manager"],
    backHref: "/orders", backLabel: "Orders",
    option: "channel",
    columns: [
      { key: "external_order_id", heading: "Order id", required: true, type: "text", sample: "402-1234567-8901234", aliases: ["external_order_id", "Order ID", "Order number"] },
      { key: "order_date", heading: "Order date", type: "date", sample: "2026-10-01", aliases: ["Date"] },
      { key: "sku", heading: "SKU", required: true, type: "text", sample: "TEE-BLK-M", hint: "Our SKU. An unknown SKU is an error." },
      { key: "quantity", heading: "Quantity", type: "number", sample: "2", aliases: ["Qty"] },
      { key: "unit_price", heading: "Unit price", type: "number", sample: "499", aliases: ["Price", "Item price"] },
      { key: "discount", heading: "Discount", type: "number", sample: "0" },
      { key: "tax", heading: "Tax", type: "number", sample: "49.9", hint: "GST amount for this line.", aliases: ["GST", "GST amount"] },
      { key: "ship_to_state", heading: "Ship-to state", type: "text", sample: "Maharashtra", hint: "Needed to split GST into CGST+SGST or IGST.", aliases: ["State", "Shipping state", "Customer state"] },
      { key: "customer_gstin", heading: "Customer GSTIN", type: "text", sample: "", aliases: ["GSTIN", "Buyer GSTIN"] },
      { key: "customer_ref", heading: "Customer ref", type: "text", sample: "", aliases: ["customer_ref", "Customer"] },
      { key: "payment_type", heading: "Payment type", list: ["prepaid", "cod"], sample: "prepaid" },
      { key: "fulfilment_status", heading: "Fulfilment status", list: ["pending", "processing", "shipped", "delivered", "cancelled", "rto"], sample: "pending" },
      { key: "payment_status", heading: "Payment status", list: ["pending", "paid", "partially_paid", "refunded", "failed"], sample: "pending" },
    ],
    notes: [
      "Rows with the same order id become one order. If any line of an order has an error, the whole order is held back.",
      "An order that already exists is never rewritten. Only a missing state or GSTIN is filled in, so an old import can be repaired.",
      "Amounts are worked out from the line items: gross = quantity x unit price, net = gross - discount + tax.",
    ],
  },
};

export const KIND_ORDER = ["products", "opening_stock", "stock_count", "listing_map", "ledger_opening", "orders", "settlement"];

export const MAX_ROWS = 5000;
