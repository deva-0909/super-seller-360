"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function ChannelStatusToggle({
  channelId,
  status,
}: {
  channelId: string;
  status: string;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);

  async function toggle() {
    setLoading(true);
    const nextStatus = status === "active" ? "inactive" : "active";
    const { error } = await supabase
      .from("channels")
      .update({ status: nextStatus })
      .eq("channel_id", channelId);
    setLoading(false);
    if (!error) {
      router.refresh();
    }
  }

  return (
    <button
      onClick={toggle}
      disabled={loading}
      className="text-xs text-ink-muted hover:text-ink disabled:opacity-50"
    >
      {status === "active" ? "Deactivate" : "Activate"}
    </button>
  );
}
