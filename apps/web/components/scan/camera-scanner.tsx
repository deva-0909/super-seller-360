"use client";

import { useEffect, useRef, useState } from "react";

type Detector = { detect: (v: HTMLVideoElement) => Promise<{ rawValue: string }[]> };
type DetectorCtor = new (o?: { formats?: string[] }) => Detector;

/**
 * Full-screen camera reader for barcodes and QR codes. Uses the browser's built-in reader where it has one (Chrome, Edge, Android),
 * and a bundled reader elsewhere (iPhone Safari). The same code is ignored for 1.5 seconds so one item is not counted many times.
 * For hundreds of items a hardware scanner is far faster; the camera is for the odd item and for people without a scanner.
 */
export function CameraScanner({ onCode, onClose }: { onCode: (code: string) => void; onClose: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const [err, setErr] = useState<string | null>(null);
  const [last, setLast] = useState<string>("");
  const cb = useRef(onCode);
  useEffect(() => { cb.current = onCode; }, [onCode]);

  useEffect(() => {
    let stopped = false;
    let stream: MediaStream | null = null;
    let timer: ReturnType<typeof setInterval> | null = null;
    let zxingStop: (() => void) | null = null;
    const recent = new Map<string, number>();
    const emit = (code: string) => {
      const now = Date.now();
      if ((recent.get(code) ?? 0) > now - 1500) return;
      recent.set(code, now);
      setLast(code);
      cb.current(code);
    };

    async function start() {
      const el = video.current;
      if (!el) return;
      try {
        const BD = (window as unknown as { BarcodeDetector?: DetectorCtor }).BarcodeDetector;
        if (BD) {
          stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
          if (stopped) { stream.getTracks().forEach((t) => t.stop()); return; }
          el.srcObject = stream;
          await el.play();
          const det = new BD({ formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code", "data_matrix"] });
          let busy = false;
          timer = setInterval(async () => {
            if (busy || el.readyState < 2) return;
            busy = true;
            try { for (const c of await det.detect(el)) if (c.rawValue) emit(c.rawValue); } catch { /* frame not ready */ }
            busy = false;
          }, 150);
        } else {
          const { BrowserMultiFormatReader } = await import("@zxing/browser");
          const reader = new BrowserMultiFormatReader();
          const controls = await reader.decodeFromVideoDevice(undefined, el, (result) => { if (result) emit(result.getText()); });
          zxingStop = () => controls.stop();
          if (stopped) controls.stop();
        }
      } catch (e) {
        const m = e instanceof Error ? e.message : "";
        setErr(/denied|permission|NotAllowed/i.test(m)
          ? "The camera is blocked. Allow camera access for this site in the browser's address bar and open it again."
          : "The camera could not be started on this device. Use a scanner, or type the code.");
      }
    }
    void start();
    return () => {
      stopped = true;
      if (timer) clearInterval(timer);
      zxingStop?.();
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black/90 p-4" role="dialog" aria-modal="true" aria-label="Camera scanner">
      <div className="mx-auto flex w-full max-w-lg flex-1 flex-col gap-3">
        <video ref={video} playsInline muted className="max-h-[60vh] w-full flex-1 bg-black object-cover" />
        {err ? <p role="alert" className="bg-danger-tint p-3 text-sm text-danger">{err}</p> : <p className="text-center text-sm text-white">Point at a barcode or QR code. Each read is counted once.</p>}
        {last ? <p className="text-center font-data text-sm text-white/80">Last read: {last}</p> : null}
        <button type="button" onClick={onClose} className="h-12 bg-white text-sm font-semibold text-black">Done</button>
      </div>
    </div>
  );
}
