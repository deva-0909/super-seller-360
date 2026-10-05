// Plain-language question matcher. No AI model: a fixed set of question types, picked by keywords.
export type IntentId = "top_products" | "low_stock" | "returns" | "pending_orders" | "anomalies" | "work" | "sales";
export type Parsed = { intent: IntentId | null; days: number; label: string };

const INTENTS: { id: IntentId; words: string[] }[] = [
  { id: "top_products", words: ["top", "best", "selling", "bestseller", "popular"] },
  { id: "low_stock", words: ["stock", "reorder", "re-order", "low", "running out", "out of"] },
  { id: "returns", words: ["rto", "return", "returned", "returns"] },
  { id: "pending_orders", words: ["pending", "unshipped", "not shipped", "to ship", "undelivered"] },
  { id: "anomalies", words: ["anomal", "unusual", "below cost", "suspicious", "wrong"] },
  { id: "work", words: ["work", "todo", "to do", "attention", "need to do", "tasks"] },
  { id: "sales", words: ["sale", "sales", "revenue", "sold", "turnover", "business", "orders"] },
];

export function parseQuestion(q: string): Parsed {
  const t = q.toLowerCase();
  let best: IntentId | null = null; let score = 0;
  for (const i of INTENTS) {
    const s = i.words.filter((w) => t.includes(w)).length;
    if (s > score) { best = i.id; score = s; }
  }
  let days = 7; let label = "last 7 days";
  const n = t.match(/(\d+)\s*day/);
  if (n) { days = Math.min(Math.max(Number(n[1]), 1), 365); label = `last ${days} days`; }
  else if (t.includes("today")) { days = 1; label = "today"; }
  else if (t.includes("yesterday")) { days = 2; label = "yesterday and today"; }
  else if (t.includes("month")) { days = 30; label = "last 30 days"; }
  else if (t.includes("week")) { days = 7; label = "last 7 days"; }
  else if (t.includes("year")) { days = 365; label = "last 365 days"; }
  return { intent: best, days, label };
}

export const EXAMPLES = [
  "Sales in the last 30 days",
  "Top selling products this month",
  "What is running low on stock?",
  "How many orders are pending?",
  "Returns in the last 30 days",
  "What needs my attention?",
  "Any unusual orders?",
];
