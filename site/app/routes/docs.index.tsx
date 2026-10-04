import { redirect } from "react-router";

export function loader() {
  return redirect("/docs/introduction");
}

export default function DocsIndex() {
  return null;
}
