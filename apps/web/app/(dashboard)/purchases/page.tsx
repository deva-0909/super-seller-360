import { redirect } from "next/navigation";

export default function PurchasesIndex() {
  redirect("/purchases/orders");
}
