/**
 * QR code generator written for this app (no outside service, no outside package, nothing that can expire).
 * It makes a Version 1 symbol (21 x 21 modules) with error correction level M, which holds up to 34 digits or 14 characters,
 * plenty for our own product codes. The result is a plain SVG string. The standard is ISO/IEC 18004.
 */

const SIZE = 21;
const DATA_WORDS = 16;
const ECC_WORDS = 10;

function gfMul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsDivisor(degree: number): number[] {
  const result: number[] = new Array(degree - 1).fill(0);
  result.push(1);
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < result.length; j++) {
      result[j] = gfMul(result[j], root);
      if (j + 1 < result.length) result[j] ^= result[j + 1];
    }
    root = gfMul(root, 2);
  }
  return result;
}

function rsRemainder(data: number[], divisor: number[]): number[] {
  const result: number[] = divisor.map(() => 0);
  for (const b of data) {
    const factor = b ^ (result.shift() as number);
    result.push(0);
    divisor.forEach((coef, i) => { result[i] ^= gfMul(coef, factor); });
  }
  return result;
}

function toDataCodewords(text: string): number[] {
  const bits: number[] = [];
  const put = (val: number, len: number) => { for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
  if (/^[0-9]+$/.test(text)) {
    if (text.length > 34) throw new Error("Too long for a version 1 QR code");
    put(0b0001, 4); put(text.length, 10);
    for (let i = 0; i < text.length; i += 3) {
      const chunk = text.slice(i, i + 3);
      put(parseInt(chunk, 10), chunk.length === 3 ? 10 : chunk.length === 2 ? 7 : 4);
    }
  } else {
    const bytes = Array.from(new TextEncoder().encode(text));
    if (bytes.length > 14) throw new Error("Too long for a version 1 QR code");
    put(0b0100, 4); put(bytes.length, 8);
    bytes.forEach((b) => put(b, 8));
  }
  const capacity = DATA_WORDS * 8;
  put(0, Math.min(4, capacity - bits.length));
  while (bits.length % 8 !== 0) bits.push(0);
  const words: number[] = [];
  for (let i = 0; i < bits.length; i += 8) words.push(parseInt(bits.slice(i, i + 8).join(""), 2));
  for (let pad = 0xec; words.length < DATA_WORDS; pad ^= 0xec ^ 0x11) words.push(pad);
  return words;
}

const MASKS: ((x: number, y: number) => boolean)[] = [
  (x, y) => (x + y) % 2 === 0,
  (_x, y) => y % 2 === 0,
  (x) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

/** the symbol as rows of booleans (true = dark module) */
export function qrModules(text: string): boolean[][] {
  const data = toDataCodewords(text);
  const all = data.concat(rsRemainder(data, rsDivisor(ECC_WORDS)));
  const m: boolean[][] = Array.from({ length: SIZE }, () => new Array(SIZE).fill(false));
  const fn: boolean[][] = Array.from({ length: SIZE }, () => new Array(SIZE).fill(false));
  const setFn = (x: number, y: number, dark: boolean) => { m[y][x] = dark; fn[y][x] = true; };

  for (let i = 0; i < SIZE; i++) { setFn(6, i, i % 2 === 0); setFn(i, 6, i % 2 === 0); }
  for (const [cx, cy] of [[3, 3], [SIZE - 4, 3], [3, SIZE - 4]]) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const x = cx + dx, y = cy + dy;
      if (x >= 0 && x < SIZE && y >= 0 && y < SIZE) setFn(x, y, Math.max(Math.abs(dx), Math.abs(dy)) !== 2 && Math.max(Math.abs(dx), Math.abs(dy)) !== 4);
    }
  }
  const formatBits = (mask: number) => {
    const d = (0 << 3) | mask; // error correction level M = 00
    let rem = d;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    return ((d << 10) | rem) ^ 0x5412;
  };
  const drawFormat = (mask: number) => {
    const bits = formatBits(mask);
    const bit = (i: number) => ((bits >>> i) & 1) !== 0;
    for (let i = 0; i <= 5; i++) setFn(8, i, bit(i));
    setFn(8, 7, bit(6)); setFn(8, 8, bit(7)); setFn(7, 8, bit(8));
    for (let i = 9; i < 15; i++) setFn(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) setFn(SIZE - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) setFn(8, SIZE - 15 + i, bit(i));
    setFn(8, SIZE - 8, true);
  };
  drawFormat(0);

  // data and error-correction bits, zig-zag from the bottom right
  let i = 0;
  for (let right = SIZE - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < SIZE; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const y = ((right + 1) & 2) === 0 ? SIZE - 1 - vert : vert;
        if (!fn[y][x] && i < all.length * 8) { m[y][x] = ((all[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0; i++; }
      }
    }
  }

  const applyMask = (k: number) => {
    for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) if (!fn[y][x] && MASKS[k](x, y)) m[y][x] = !m[y][x];
  };
  const penalty = () => {
    let p = 0;
    for (let pass = 0; pass < 2; pass++) {
      for (let a = 0; a < SIZE; a++) {
        let run = 1;
        for (let b = 1; b < SIZE; b++) {
          const cur = pass === 0 ? m[a][b] : m[b][a], prev = pass === 0 ? m[a][b - 1] : m[b - 1][a];
          if (cur === prev) { run++; if (run === 5) p += 3; else if (run > 5) p++; } else run = 1;
        }
        const line = Array.from({ length: SIZE }, (_, b) => (pass === 0 ? m[a][b] : m[b][a]) ? "1" : "0").join("");
        for (const pat of ["10111010000", "00001011101"]) { let at = line.indexOf(pat); while (at >= 0) { p += 40; at = line.indexOf(pat, at + 1); } }
      }
    }
    for (let y = 0; y < SIZE - 1; y++) for (let x = 0; x < SIZE - 1; x++) if (m[y][x] === m[y][x + 1] && m[y][x] === m[y + 1][x] && m[y][x] === m[y + 1][x + 1]) p += 3;
    const dark = m.flat().filter(Boolean).length;
    p += Math.floor(Math.abs(dark * 20 - SIZE * SIZE * 10) / (SIZE * SIZE)) * 10;
    return p;
  };
  let best = 0, bestP = Infinity;
  for (let k = 0; k < 8; k++) {
    applyMask(k); drawFormat(k);
    const p = penalty();
    if (p < bestP) { bestP = p; best = k; }
    applyMask(k);
  }
  applyMask(best); drawFormat(best);
  return m;
}

/** SVG markup for the code, with the 4-module quiet zone the standard asks for */
export function qrSvg(text: string): string {
  const m = qrModules(text);
  const q = 4, n = SIZE + q * 2;
  let d = "";
  for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) if (m[y][x]) d += `M${x + q},${y + q}h1v1h-1z`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges" style="width:100%;height:100%"><rect width="${n}" height="${n}" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
}
