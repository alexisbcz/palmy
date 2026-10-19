import { redirect } from "react-router";

export function loader() {
  return redirect("/distro/overview");
}

export default function DistroIndex() {
  return null;
}
