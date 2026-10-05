import { AccessGuard } from "@/components/shell/access-guard";
import { GstTabs } from "@/components/gst/gst-tabs";

export default function GstLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <GstTabs />
      <AccessGuard gate="gst_view">{children}</AccessGuard>
    </div>
  );
}
