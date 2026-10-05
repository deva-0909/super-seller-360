import { MfaPanel } from "./mfa-panel";

export default function SecurityPage() {
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Security</h1>
      <p className="mt-1 text-sm text-ink-muted">Protect your sign-in with a one-time code from your phone.</p>
      <MfaPanel />
    </div>
  );
}
