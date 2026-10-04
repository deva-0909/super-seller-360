// How the credit in the electronic credit ledger is applied against the tax payable (Section 49 and Rule 88A of the CGST Rules, as understood
// by the author; confirm with your CA). Credits that cannot be used are carried forward; the rest of the tax is paid in cash.

export type Heads = { igst: number; cgst: number; sgst: number };

const r2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;

export type SetOff = {
  /** credit used, by [credit head][liability head] */
  used: { igst: Heads; cgst: Heads; sgst: Heads };
  cash: Heads;
  carryForward: Heads;
};

export function setOff(liability: Heads, credit: Heads): SetOff {
  const L = { ...liability };
  const C = { ...credit };
  const used = {
    igst: { igst: 0, cgst: 0, sgst: 0 },
    cgst: { igst: 0, cgst: 0, sgst: 0 },
    sgst: { igst: 0, cgst: 0, sgst: 0 },
  };
  const applyCredit = (from: keyof Heads, to: keyof Heads) => {
    const t = Math.min(C[from], L[to]);
    if (t > 0) { C[from] = r2(C[from] - t); L[to] = r2(L[to] - t); used[from][to] = r2(used[from][to] + t); }
  };
  // 1. integrated tax credit goes against integrated tax first
  applyCredit("igst", "igst");
  // 2. central and state credit against their own tax
  applyCredit("cgst", "cgst");
  applyCredit("sgst", "sgst");
  // 3. what integrated tax is still due: central credit, then state credit
  applyCredit("cgst", "igst");
  applyCredit("sgst", "igst");
  // 4. leftover integrated credit against central tax, then state tax
  applyCredit("igst", "cgst");
  applyCredit("igst", "sgst");
  return { used, cash: { igst: r2(Math.max(L.igst, 0)), cgst: r2(Math.max(L.cgst, 0)), sgst: r2(Math.max(L.sgst, 0)) }, carryForward: { igst: r2(C.igst), cgst: r2(C.cgst), sgst: r2(C.sgst) } };
}
