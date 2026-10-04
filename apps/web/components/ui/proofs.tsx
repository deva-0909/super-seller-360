"use client";

import { useEffect, useRef, useState } from "react";
import { discardProof, listProofs, uploadProof, type EntityType, type Proof } from "@/lib/attachments";

const btn = "inline-flex h-10 items-center justify-center rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
const sizeText = (n: number | null) => (n == null ? "" : n > 1_000_000 ? `${(n / 1_000_000).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1000))} KB`);

function Thumb({ p }: { p: Proof }) {
  const isImg = (p.mime_type ?? "").startsWith("image/") && p.url;
  const inner = isImg ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={p.url ?? ""} alt={p.file_name} className="h-14 w-14 shrink-0 border border-line object-cover" />
  ) : (
    <span className="flex h-14 w-14 shrink-0 items-center justify-center border border-line bg-surface-sunken text-xs font-semibold text-ink-muted">PDF</span>
  );
  return p.url ? <a href={p.url} target="_blank" rel="noreferrer" aria-label={`Open ${p.file_name}`}>{inner}</a> : inner;
}

/**
 * Proof / attachment picker.
 *  - With `entityId` (a record that already exists) it lists that record's files and uploads straight onto it.
 *  - Without it (a form not yet submitted) files are uploaded as "pending" and handed to the parent through
 *    `pending` / `onPending`; after saving, the parent calls linkProofs(ids, type, newId).
 * "Take photo" opens the phone camera; "Gallery or files" opens the gallery / file picker. On a computer both open the file dialog.
 */
export function Proofs({
  entityType, entityId = null, pending = [], onPending, kind = "receipt", label = "Proof / attachments", hint, readOnly = false,
}: {
  entityType: EntityType; entityId?: string | null; pending?: Proof[]; onPending?: (p: Proof[]) => void;
  kind?: string; label?: string; hint?: string; readOnly?: boolean;
}) {
  const [saved, setSaved] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const cam = useRef<HTMLInputElement>(null);
  const gal = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!entityId) return;
    let alive = true;
    listProofs(entityType, entityId).then((r) => { if (alive) setSaved(r); }, (e: Error) => { if (alive) setErr(e.message); });
    return () => { alive = false; };
  }, [entityType, entityId]);

  async function onFiles(files: FileList | null) {
    if (!files?.length) return;
    setBusy(true); setErr(null);
    const done: Proof[] = [];
    try {
      for (const f of Array.from(files)) done.push(await uploadProof(f, entityType, entityId, { kind }));
    } catch (e) {
      setErr((e as Error).message);
    }
    setBusy(false);
    if (cam.current) cam.current.value = "";
    if (gal.current) gal.current.value = "";
    if (!done.length) return;
    if (entityId) setSaved((s) => [...s, ...done]);
    else onPending?.([...pending, ...done]);
  }

  async function remove(p: Proof) {
    setErr(null);
    try { await discardProof(p); onPending?.(pending.filter((x) => x.attachment_id !== p.attachment_id)); }
    catch (e) { setErr((e as Error).message); }
  }

  const shown = entityId ? saved : pending;
  return (
    <div>
      <p className="text-sm font-medium text-ink">{label}</p>
      {hint ? <p className="mt-0.5 text-xs text-ink-muted">{hint}</p> : null}
      {shown.length ? (
        <ul className="mt-2 space-y-2">
          {shown.map((p) => (
            <li key={p.attachment_id} className="flex items-center gap-3">
              <Thumb p={p} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm text-ink">{p.file_name}</p>
                <p className="text-xs text-ink-muted">{sizeText(p.size_bytes)}{p.uploaded_at ? ` · ${p.uploaded_at.slice(0, 10)}` : ""}</p>
              </div>
              {!entityId && !readOnly ? <button type="button" className="text-xs font-semibold text-danger" onClick={() => remove(p)}>Remove</button> : null}
            </li>
          ))}
        </ul>
      ) : readOnly ? <p className="mt-1 text-xs text-ink-muted">No attachments.</p> : null}
      {!readOnly ? (
        <div className="mt-2 flex flex-wrap gap-2">
          <button type="button" className={btn} disabled={busy} onClick={() => cam.current?.click()}>Take photo</button>
          <button type="button" className={btn} disabled={busy} onClick={() => gal.current?.click()}>Gallery or files</button>
          {busy ? <span className="self-center text-xs text-ink-muted">Uploading…</span> : null}
          <input ref={cam} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => onFiles(e.target.files)} />
          <input ref={gal} type="file" accept="image/*,application/pdf" multiple className="hidden" onChange={(e) => onFiles(e.target.files)} />
        </div>
      ) : null}
      {err ? <p role="alert" className="mt-1 text-xs text-danger">{err}</p> : null}
    </div>
  );
}
