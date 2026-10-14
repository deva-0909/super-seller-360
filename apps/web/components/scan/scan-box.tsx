"use client";

import { forwardRef, useImperativeHandle, useRef, useState } from "react";
import { CameraScanner } from "./camera-scanner";

export type ScanBoxHandle = { focus: () => void };

/**
 * The scan field. A USB or Bluetooth scanner types the code and presses Enter, so it works with no setup as long as the cursor is here.
 * The phone-camera button reads barcodes and QR codes through the camera instead.
 */
export const ScanBox = forwardRef<ScanBoxHandle, { onScan: (code: string) => void; disabled?: boolean }>(function ScanBox({ onScan, disabled }, ref) {
  const input = useRef<HTMLInputElement>(null);
  const [focused, setFocused] = useState(false);
  const [camera, setCamera] = useState(false);
  useImperativeHandle(ref, () => ({ focus: () => input.current?.focus() }));

  function submit() {
    const v = input.current?.value.trim() ?? "";
    if (input.current) input.current.value = "";
    if (v) onScan(v);
  }

  return (
    <div>
      <div className="flex flex-wrap items-center gap-2">
        <input
          ref={input}
          autoFocus
          disabled={disabled}
          inputMode="none"
          autoComplete="off"
          autoCapitalize="off"
          spellCheck={false}
          placeholder="Scan here (or type a barcode / SKU and press Enter)"
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === "Tab") {
              if ((input.current?.value ?? "").trim()) { e.preventDefault(); submit(); }
            }
          }}
          className={`h-12 min-w-[240px] flex-1 border-2 bg-surface px-3 font-data text-base text-ink outline-none ${focused ? "border-success" : "border-warning"}`}
        />
        <button type="button" disabled={disabled} onClick={() => setCamera(true)} className="h-12 border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">
          Use phone camera
        </button>
      </div>
      <p className={`mt-1 text-xs ${focused ? "text-success" : "text-warning"}`}>
        {focused ? "Ready: scan now." : "Click the box above before scanning, or the scanner's digits will go nowhere."}
      </p>
      {camera ? <CameraScanner onCode={onScan} onClose={() => { setCamera(false); input.current?.focus(); }} /> : null}
    </div>
  );
});
