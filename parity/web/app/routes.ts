import { type RouteConfig, index, route } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),
  route("parity", "routes/parity.tsx"),
  route("parity/cases.json", "routes/parity.cases.json.ts"),
  route("iso/:id", "routes/iso.tsx"),
] satisfies RouteConfig;
