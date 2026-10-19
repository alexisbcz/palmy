/**
 * What the Markdown-driven half of the site is made of.
 *
 * Most pages here are not written for the site: they are the repository's own
 * Markdown (distro/README.md, the contracts, the per-area notes, TODO.md),
 * pulled in by `npm run sync` so the site says what the repository says. The
 * rest are short pages in ./pages that stitch those sources together, and
 * reference pages generated from the Odin source.
 *
 * A page's `source` is one of:
 *
 *   { file }                    the whole file, its `#` title dropped
 *   { file, section }           one heading and everything under it
 *   { file, section, intro }    that heading's text before its first subheading
 *   { file, intro }             the file's text before its first `##`
 *   { page }                    a hand-written page in ./pages
 *
 * `edit` overrides where "Edit on GitHub" points; `generated` lists the files a
 * page's tables are read from. `note` is a callout placed above the content,
 * used where a synced document is older than the code it describes.
 */

export const REPO = "alexisbcz/palmy";
export const BRANCH = "main";

/** @type {Record<string, {base: string, title: string, groups: {title: string, pages: any[]}[]}>} */
export const COLLECTIONS = {
  distro: {
    base: "/distro",
    title: "Distribution",
    groups: [
      {
        title: "Getting started",
        pages: [
          {
            slug: "overview",
            title: "Palmframe, the distribution",
            nav: "Overview",
            description:
              "What the distribution is, what it is modelled on, and where it stands: it boots in QEMU to a desktop and installs onto a disk, and has never run on real hardware.",
            source: { file: "distro/README.md", intro: true },
            after: { page: "overview-next.md" },
          },
          {
            slug: "quick-start",
            title: "Quick start",
            description:
              "Build the toolkit, build the disk image, boot it in QEMU, then build the live ISO and install from it. Every command, in order.",
            source: { page: "quick-start.md" },
          },
          {
            slug: "build-and-run",
            title: "Building and running",
            description:
              "make targets, distro/run-qemu.sh options, and the accounts on the disk image.",
            source: { file: "distro/README.md", section: "Building and running" },
          },
        ],
      },
      {
        title: "Using it",
        pages: [
          {
            slug: "window-manager",
            title: "The window manager",
            description:
              "wm, palmy's Wayland compositor: what it does on bare metal, every default key binding and mouse gesture, and the wm.conf format. The tables are read from apps/wm.",
            source: { page: "window-manager.md" },
            generated: ["apps/wm/config.odin", "apps/wm/keys.odin", "apps/wm/cheatsheet.odin"],
          },
          {
            slug: "installing",
            title: "Installing",
            description:
              "The live ISO, the eight-step graphical installer, palm-install on the command line, the languages, what an install writes and the UEFI boot entry.",
            source: { file: "distro/README.md", section: "Installing" },
          },
          {
            slug: "software",
            title: "Software and palmd",
            description:
              "The graphical face of palm, and the small root daemon that lets members of wheel install and remove packages.",
            source: { file: "distro/README.md", section: "Software and palmd" },
          },
          {
            slug: "applications",
            title: "Applications on Palmframe",
            nav: "Applications",
            description:
              "Every palmy application, whether it builds, whether it works on the bare system, what it needs at runtime, and which are installed by default. Read from distro/apps/apps.tsv.",
            source: { page: "applications.md" },
            generated: ["distro/apps/apps.tsv", "distro/apps/default.list"],
          },
        ],
      },
      {
        title: "Architecture",
        pages: [
          {
            slug: "architecture",
            title: "Architecture",
            description:
              "The boot chain from firmware to the desktop, and the directories each piece lives in.",
            source: { page: "architecture.md" },
            generated: ["distro/README.md"],
          },
          {
            slug: "palm-init",
            title: "palm-init",
            description:
              "PID 1: mounts, device permissions, services as key = value files, restarts with backoff, and shutdown.",
            source: { file: "distro/README.md", section: "palm-init" },
          },
          {
            slug: "palm-login",
            title: "palm-login",
            description:
              "The login daemon: greetd's IPC protocol, SHA-512 crypt in Odin, the greeter and session loop, and power actions.",
            source: { file: "distro/README.md", section: "palm-login" },
          },
          {
            slug: "palm",
            title: "palm, the package manager",
            nav: "palm",
            description:
              "Modelled on Alpine's apk: a world file, signed indexes, declarative recipes, reproducible builds. Commands, formats and the repository.",
            source: { file: "distro/README.md", section: "palm" },
          },
          {
            slug: "packages",
            title: "Package list",
            description:
              "Every package in the repository, its version, what it depends on, and whether the palmframe meta-package installs it. Read from distro/recipes.",
            source: { page: "packages.md" },
            generated: ["distro/recipes"],
          },
          {
            slug: "contract",
            title: "The contract",
            description:
              "The interfaces every piece of the distribution was built against: filesystem layout, PID 1, users, the session, palm, build outputs and QEMU.",
            source: { file: "distro/CONTRACT.md" },
          },
          {
            slug: "installer-reference",
            title: "Installer reference",
            description:
              "The install_core API, palm-install, the configuration files an installed system honours, the i18n library and the live image.",
            source: { file: "distro/INSTALLER.md" },
          },
        ],
      },
      {
        title: "Status",
        pages: [
          {
            slug: "verified",
            title: "What has been verified",
            description:
              "What was run inside QEMU and observed, step by step, with the screenshots it produced.",
            source: { file: "distro/README.md", section: "What has been verified", level: 2 },
          },
          {
            slug: "missing",
            title: "What is missing",
            description:
              "The system boots, logs in and installs packages. It is not something to run on real hardware yet. This is the list of why.",
            source: { file: "distro/README.md", section: "What is missing" },
          },
          {
            slug: "roadmap",
            title: "Roadmap",
            description:
              "TODO.md: what is not done, in the order it is worth doing, with a prompt for each.",
            source: { file: "TODO.md" },
          },
        ],
      },
      {
        title: "Design documents",
        pages: [
          {
            slug: "command-surface",
            title: "The palm command surface",
            nav: "Command surface",
            description:
              "One CLI through which an agent can operate every part of Palmframe: the convention every application's command line follows.",
            source: { file: "docs/PALM-CLI.md" },
            note: {
              type: "warning",
              title: "Partly out of date",
              body: "This document opens by saying none of it exists. TODO.md records that this is now false: the convention is implemented in `apps/kit/cli.odin`, and bringing the rest of the applications up to it is open work. See [the roadmap](/distro/roadmap#the-command-surface).",
            },
          },
          {
            slug: "package-design",
            title: "Packages, the earlier design",
            nav: "Packages (earlier design)",
            description:
              "A design for a declarative layer over pacman, written before the distribution existed.",
            source: { file: "docs/PACKAGES.md" },
            note: {
              type: "warning",
              title: "Superseded for the distribution",
              body: "This was written before `distro/` existed and argues against writing a package manager. The distribution went on to build its own, [palm](/distro/palm), modelled on Alpine's apk. It is kept because the reasoning about an agent-operable interface still applies.",
            },
          },
          {
            slug: "cloud-contract",
            title: "The cloud contract",
            nav: "Cloud contract",
            description:
              "The interfaces the account, mail and drive pieces of the cloud part are being built against: layout, ownership and what each piece must agree on.",
            source: { file: "cloud/CONTRACT.md" },
            note: {
              type: "info",
              title: "A contract for work in progress",
              body: "The pieces this file describes are being built against it now. None of them is part of the distribution yet; the idea behind them is on [The cloud part](/palmframe/cloud).",
            },
          },
          {
            slug: "wm-interaction-model",
            title: "The window manager's interaction model",
            nav: "wm interaction model",
            description:
              "The spec for how the window manager should feel under the hands, starting from an audit of what it did when the spec was written.",
            source: { file: "apps/wm/UX.md" },
            note: {
              type: "info",
              title: "A spec, with an audit dated to when it was written",
              body: "Section 1 describes the window manager before the rework this spec asked for. The current key bindings and gestures are on [The window manager](/distro/window-manager), read from the source.",
            },
          },
        ],
      },
      {
        title: "Engineering notes",
        pages: [
          ["notes-integrate", "Integration", "distro/notes/integrate.md", "From the pieces to a bootable Palmframe: build order, packages, what was verified and the known gaps."],
          ["notes-init", "palm-init notes", "distro/notes/init.md", "palm-init and palmframe-base: what the other pieces need to know."],
          ["notes-login", "palm-login and greeter notes", "distro/notes/login.md", "palm-login and the greeter: power actions, knobs for images and tests, and open points."],
          ["notes-palm", "palm notes", "distro/notes/palm.md", "The palm side: the CLI as built, format decisions the contract left open, and what was verified."],
          ["notes-store", "Software and palmd notes", "distro/notes/store.md", "Decisions behind Software and palmd, and the verification run."],
          ["notes-wm", "wm on bare metal", "distro/notes/wm.md", "What palm-login gets from wm --drm, keyboard layouts and local time, and the known gaps."],
          ["notes-apps", "Applications notes", "distro/notes/apps.md", "What the applications need at runtime on Palmframe, and what changed in palmy for it."],
          ["notes-live", "Live image notes", "distro/notes/live.md", "The live installer image, its services and packages, and how it was verified."],
          ["notes-installer-core", "install_core notes", "distro/notes/installer-core.md", "The install core and palm-install: the API as built, decisions, requests and gaps."],
          ["notes-installer-gui", "Graphical installer notes", "distro/notes/installer-gui.md", "apps/installer: modes, pages, right to left, translations, and where it differs from INSTALLER.md."],
          ["notes-i18n", "Translations notes", "distro/notes/i18n.md", "Translations, locale and time zone across the session stack."],
          ["notes-browser", "Browser, GPU and X11 research", "distro/notes/browser.md", "Research, nothing built: what a real web browser, GPU clients and X11 applications on Palmframe would take, and what to do first."],
        ].map(([slug, title, file, description]) => ({
          slug,
          title,
          description,
          source: { file },
        })),
      },
      {
        title: "Contributing",
        pages: [
          {
            slug: "contributing",
            title: "Contributing",
            description:
              "How the repository is laid out, how work is split, how to test a change, and how this site is built from the repository's Markdown.",
            source: { page: "contributing.md" },
          },
          {
            slug: "writing-apps",
            title: "Writing an application",
            description:
              "apps/APPS.md: building, the kit, interaction, images, text editing, recording a demo, and the rules for apps that touch the system.",
            source: { file: "apps/APPS.md" },
          },
        ],
      },
    ],
  },

  reference: {
    base: "/reference",
    title: "Reference",
    groups: [
      {
        title: "Generated reference",
        pages: [
          {
            slug: "classes",
            title: "Class reference",
            description:
              "Every Tailwind utility palmy understands, the variants, the value scales, and the utilities it accepts without effect. Read from palmy/class.odin.",
            source: { page: "classes.md" },
            generated: ["palmy/class.odin", "palmy/palette.odin", "palmy/color.odin"],
          },
          {
            slug: "palmy-api",
            title: "palmy API",
            description:
              "Every exported procedure and type in the palmy package, with its doc comment, grouped by file. Read from palmy/*.odin.",
            source: { page: "api-palmy.md" },
            generated: ["palmy"],
            tocDepth: 2,
          },
          {
            slug: "shadcn-api",
            title: "Widget package API",
            description:
              "Every exported procedure and type in the shadcn package, the Odin translations of the shadcn/ui components. Read from shadcn/*.odin.",
            source: { page: "api-shadcn.md" },
            generated: ["shadcn"],
            tocDepth: 2,
          },
        ],
      },
    ],
  },
};
