import { type RouteConfig, index, route } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),

  route("docs", "routes/docs.index.tsx"),
  route("docs/:slug", "routes/docs.slug.tsx"),

  route("palmframe", "routes/palmframe.index.tsx"),
  route("palmframe/:slug", "routes/palmframe.slug.tsx"),

  route("components", "routes/components.index.tsx"),
  route("components/:slug", "routes/components.slug.tsx"),

  route("apps", "routes/apps.tsx"),
] satisfies RouteConfig;
