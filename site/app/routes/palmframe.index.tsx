import { redirect } from "react-router";

export function loader() {
  return redirect("/palmframe/overview");
}

export default function PalmframeIndex() {
  return null;
}
