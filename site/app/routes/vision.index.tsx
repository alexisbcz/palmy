import { redirect } from "react-router";

export function loader() {
  return redirect("/vision/overview");
}

export default function PalmyIndex() {
  return null;
}
