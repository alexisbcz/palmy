import { type RouteConfig, index, route } from "@react-router/dev/routes";

export default [
  index("routes/home.tsx"),

  route("docs", "routes/docs.index.tsx"),
  route("docs/:slug", "routes/docs.slug.tsx"),

  route("vision", "routes/vision.index.tsx"),
  route("vision/:slug", "routes/vision.slug.tsx"),

  route("components", "routes/components.index.tsx"),
  route("components/:slug", "routes/components.slug.tsx"),

  route("apps", "routes/apps.tsx"),

  route("distro", "routes/distro.index.tsx"),
  route("distro/:slug", "routes/distro.slug.tsx"),

  route("reference", "routes/reference.index.tsx"),
  route("reference/:slug", "routes/reference.slug.tsx"),
] satisfies RouteConfig;
