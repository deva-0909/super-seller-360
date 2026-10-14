// Sound and vibration for every scan, so the person at the dock does not have to look at the screen.
let ctx: AudioContext | null = null;

export function beep(tone: "ok" | "warn" | "bad") {
  try {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return;
    ctx = ctx ?? new AC();
    if (ctx.state === "suspended") void ctx.resume();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    const f = tone === "ok" ? 1100 : tone === "warn" ? 600 : 220;
    o.type = tone === "bad" ? "square" : "sine";
    o.frequency.value = f;
    g.gain.value = 0.08;
    const t = ctx.currentTime;
    o.start(t);
    o.stop(t + (tone === "ok" ? 0.07 : tone === "warn" ? 0.15 : 0.35));
  } catch { /* no audio available: the on-screen message still shows */ }
  try {
    navigator.vibrate?.(tone === "ok" ? 20 : tone === "warn" ? [40, 40, 40] : 250);
  } catch { /* not supported */ }
}
