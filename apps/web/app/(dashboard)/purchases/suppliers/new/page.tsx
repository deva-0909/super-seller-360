import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { SupplierForm } from "../supplier-form";

export default async function NewSupplierPage() {
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: states }, { data: sections }] = await Promise.all([
    supabase.from("gst_states").select("code, name").order("code"),
    supabase.from("tds_sections").select("section, description").eq("active", true).order("section"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Add supplier</h1>
      {canWrite ? (
        <SupplierForm states={states ?? []} sections={sections ?? []} showBank />
      ) : (
        <p className="mt-4 text-sm text-ink-muted">Your role can view suppliers but not add them.</p>
      )}
    </div>
  );
}
