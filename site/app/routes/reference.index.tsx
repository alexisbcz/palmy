import { redirect } from "react-router";

export function loader() {
  return redirect("/reference/classes");
}

export default function ReferenceIndex() {
  return null;
}
