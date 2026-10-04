import { loadEditorRefs } from "../loader";
import { Simulator } from "./simulator";

export default async function SimulatePage() {
  const { events } = await loadEditorRefs();
  return <Simulator events={events} />;
}
