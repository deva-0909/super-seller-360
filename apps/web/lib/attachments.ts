import { createClient } from "@/lib/supabase/client";

export type EntityType =
  | "voucher" | "cash_settlement_report" | "bank_transaction" | "cod_collection" | "settlement" | "claim" | "return" | "rto" | "tax_transaction" | "supplier_bill" | "supplier_payment" | "expense_claim";

export type Proof = {
  attachment_id: string;
  path: string;
  file_name: string;
  mime_type: string | null;
  size_bytes: number | null;
  kind: string | null;
  note: string | null;
  uploaded_at: string;
  url: string | null;
};

const BUCKET = "proofs";
export const MAX_BYTES = 15 * 1024 * 1024;
const ALLOWED = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "application/pdf"];
const COLUMNS = "attachment_id, path, file_name, mime_type, size_bytes, kind, note, uploaded_at";

/** Phone photos are 3-8 MB. Shrink them (longest side 1600px, JPEG) before uploading so it is quick on mobile data. */
export async function shrinkImage(file: File, maxSide = 1600, quality = 0.82): Promise<File> {
  if (!/^image\/(jpeg|png|webp)$/.test(file.type) || typeof createImageBitmap !== "function") return file;
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, maxSide / Math.max(bmp.width, bmp.height));
    if (scale === 1 && file.size < 1_500_000) { bmp.close(); return file; }
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext("2d")?.drawImage(bmp, 0, 0, canvas.width, canvas.height);
    bmp.close();
    const blob: Blob | null = await new Promise((res) => canvas.toBlob(res, "image/jpeg", quality));
    if (!blob || blob.size >= file.size) return file;
    return new File([blob], file.name.replace(/\.\w+$/, "") + ".jpg", { type: "image/jpeg" });
  } catch {
    return file;
  }
}

const safeName = (n: string) => n.normalize("NFKD").replace(/[^\w.\-]+/g, "_").slice(-80) || "file";

export async function signedUrls(paths: string[]): Promise<Record<string, string>> {
  if (!paths.length) return {};
  const supabase = createClient();
  const { data } = await supabase.storage.from(BUCKET).createSignedUrls(paths, 3600);
  const out: Record<string, string> = {};
  for (const r of data ?? []) if (r.path && r.signedUrl) out[r.path] = r.signedUrl;
  return out;
}

/** Upload one file. With entityId it is attached straight away; without, it is kept "pending" until linkProofs(). */
export async function uploadProof(file: File, entityType: EntityType, entityId: string | null, opts: { kind?: string; note?: string } = {}): Promise<Proof> {
  const supabase = createClient();
  const f = await shrinkImage(file);
  if (!ALLOWED.includes(f.type)) throw new Error("Only photos (JPG, PNG, WebP, HEIC) and PDF files can be attached.");
  if (f.size > MAX_BYTES) throw new Error("That file is larger than 15 MB. Take the photo again at a lower size, or send a PDF.");
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Please sign in again.");
  const path = `${user.id}/${crypto.randomUUID()}-${safeName(f.name)}`;
  const up = await supabase.storage.from(BUCKET).upload(path, f, { contentType: f.type, upsert: false });
  if (up.error) throw new Error(/row-level security|not authorized|policy/i.test(up.error.message) ? "Your role cannot attach files here." : up.error.message);
  const ins = await supabase.from("attachments")
    .insert({ entity_type: entityType, entity_id: entityId, path, file_name: file.name, mime_type: f.type, size_bytes: f.size, kind: opts.kind ?? null, note: opts.note ?? null })
    .select(COLUMNS).single();
  if (ins.error) {
    await supabase.storage.from(BUCKET).remove([path]);
    throw new Error(/row-level security/i.test(ins.error.message) ? "Your role cannot attach files to this record." : ins.error.message);
  }
  const urls = await signedUrls([path]);
  return { ...(ins.data as Omit<Proof, "url">), url: urls[path] ?? null };
}

/** After the record has been saved: tie the pending files to it. */
export async function linkProofs(ids: string[], entityType: EntityType, entityId: string): Promise<void> {
  if (!ids.length) return;
  const supabase = createClient();
  const { error } = await supabase.from("attachments").update({ entity_id: entityId }).in("attachment_id", ids).eq("entity_type", entityType).is("entity_id", null);
  if (error) throw new Error(error.message);
}

/** Throw away a file that was never linked to a record. */
export async function discardProof(p: Proof): Promise<void> {
  const supabase = createClient();
  const rm = await supabase.storage.from(BUCKET).remove([p.path]);
  if (rm.error) throw new Error(rm.error.message);
  const { error } = await supabase.from("attachments").delete().eq("attachment_id", p.attachment_id);
  if (error) throw new Error(error.message);
}

export async function listProofs(entityType: EntityType, entityId: string): Promise<Proof[]> {
  const supabase = createClient();
  const { data, error } = await supabase.from("attachments").select(COLUMNS).eq("entity_type", entityType).eq("entity_id", entityId).order("uploaded_at");
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as Omit<Proof, "url">[];
  const urls = await signedUrls(rows.map((r) => r.path));
  return rows.map((r) => ({ ...r, url: urls[r.path] ?? null }));
}
