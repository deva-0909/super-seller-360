/**
 * EAN-13 barcode generator written for this app (no outside service, no outside package). Returns SVG markup.
 * A code is just 13 digits drawn as bars, so it never expires and works with any scanner.
 */

const L = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"];
const G = L.map((s) => s.split("").reverse().map((c) => (c === "0" ? "1" : "0")).join(""));
const R = L.map((s) => s.split("").map((c) => (c === "0" ? "1" : "0")).join(""));
const PARITY = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"];

export function ean13Check(first12: string): number {
  let s = 0;
  for (let i = 0; i < 12; i++) s += Number(first12[i]) * (i % 2 === 0 ? 1 : 3);
  return (10 - (s % 10)) % 10;
}
export function ean13Valid(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13Check(code.slice(0, 12)) === Number(code[12]);
}

/** the 95 modules of the symbol, as a string of 0 and 1 */
export function ean13Bits(code: string): string {
  if (!ean13Valid(code)) throw new Error("Not a valid EAN-13 number");
  const par = PARITY[Number(code[0])];
  let bits = "101";
  for (let i = 0; i < 6; i++) bits += (par[i] === "L" ? L : G)[Number(code[i + 1])];
  bits += "01010";
  for (let i = 0; i < 6; i++) bits += R[Number(code[i + 7])];
  return bits + "101";
}

export function ean13Svg(code: string, opts: { height?: number } = {}): string {
  const bits = ean13Bits(code);
  const bar = opts.height ?? 40, text = 9, left = 11, right = 7;
  const w = left + 95 + right, h = bar + text;
  const guard = (i: number) => i < 3 || (i >= 45 && i < 50) || i >= 92;
  let d = "";
  for (let i = 0; i < 95; i++) if (bits[i] === "1") d += `M${left + i},0h1v${guard(i) ? bar + 4 : bar}h-1z`;
  const t = (x: number, s: string) => `<text x="${x}" y="${h + 1}" font-family="monospace" font-size="9" text-anchor="middle" fill="#000">${s}</text>`;
  const digits = t(left - 6, code[0]) + t(left + 3 + 21, code.slice(1, 7).split("").join(" ")) + t(left + 50 + 21, code.slice(7).split("").join(" "));
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h + 3}" preserveAspectRatio="xMidYMid meet" shape-rendering="crispEdges" style="max-width:100%;height:100%"><rect width="${w}" height="${h + 3}" fill="#fff"/><path d="${d}" fill="#000"/>${digits}</svg>`;
}
