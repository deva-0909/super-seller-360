import { GstTabs } from "@/components/gst/gst-tabs";

export default function GstLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <GstTabs />
      {children}
    </div>
  );
}
