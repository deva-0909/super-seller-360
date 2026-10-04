// Builds the reminder e-mail. Pure (no network) so it can be unit tested.
export type OpenCash = { id: string; date: string; voucher_no: string | null; amount: number; open_amount: number; narration: string | null; times_mailed: number };

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
const inr = (n: number) => "Rs " + Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function buildMail(items: OpenCash[], openTotal: number, appUrl?: string) {
  const total = items.reduce((s, i) => s + Number(i.open_amount), 0);
  const link = appUrl ? appUrl.replace(/\/$/, "") + "/accounting/cash-settlement" : "";
  const repeat = items.some((i) => i.times_mailed > 0);
  const subject = `${repeat ? "Reminder: " : ""}Cash of ${inr(total)} withdrawn from the bank is not yet accounted for`;
  const rows = items
    .map((i) => `<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e5e5">${esc(i.date)}</td><td style="padding:6px 10px;border-bottom:1px solid #e5e5e5">${esc(i.voucher_no)}</td><td style="padding:6px 10px;border-bottom:1px solid #e5e5e5">${esc(i.narration)}</td><td style="padding:6px 10px;border-bottom:1px solid #e5e5e5;text-align:right">${esc(inr(i.open_amount))}</td></tr>`)
    .join("");
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#111">
<p>Money has moved from the bank into cash, and nothing has been recorded to show where the cash went.</p>
<table style="border-collapse:collapse;margin:12px 0"><thead><tr><th align="left" style="padding:6px 10px;border-bottom:2px solid #111">Date</th><th align="left" style="padding:6px 10px;border-bottom:2px solid #111">Entry</th><th align="left" style="padding:6px 10px;border-bottom:2px solid #111">Narration</th><th align="right" style="padding:6px 10px;border-bottom:2px solid #111">Still to account for</th></tr></thead><tbody>${rows}</tbody></table>
<p>Total to account for: <b>${esc(inr(total))}</b>${openTotal > items.length ? ` (${openTotal} open items in all)` : ""}.</p>
<p>Please have the cash settlement report submitted - spent, returned to the bank, or kept in hand.${link ? ` <a href="${esc(link)}">Open Cash Settlement</a>` : ""}</p>
<p style="color:#666;font-size:12px">The on-screen reminder stays until the report is submitted. This e-mail repeats until then.</p></div>`;
  const text = `Money has moved from the bank into cash and is not yet accounted for.\n\n` +
    items.map((i) => `${i.date}  ${i.voucher_no ?? ""}  ${i.narration ?? ""}  ${inr(i.open_amount)}`).join("\n") +
    `\n\nTotal to account for: ${inr(total)}\nSubmit the cash settlement report${link ? ": " + link : " in the app (Accounting > Cash Settlement)."}\n`;
  return { subject, html, text };
}
