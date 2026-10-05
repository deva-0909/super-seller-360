import { AskBox } from "./ask-box";

export default function AskPage() {
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Ask a question</h1>
      <p className="mt-1 max-w-2xl text-sm text-ink-muted">Type a question in plain words about sales, top products, stock, pending orders, returns, anomalies or your work queue. Answers come from your own data and only show what your role is allowed to see.</p>
      <AskBox />
    </div>
  );
}
