# Contributing

The repository is one checkout: the toolkit, its widget set, the applications, the distribution and this site. The code is on [GitHub](https://github.com/alexisbcz/palmy).

## Where things are

| Directory | What |
| --- | --- |
| `palmy/` | the toolkit: display protocols, rasterizer, layout, text, the class parser |
| `shadcn/` | the widget set, Odin translations of the shadcn/ui components |
| `parity/` | the suite that diffs those widgets against Chromium rendering the React source |
| `apps/` | the applications, the window manager and `apps/kit`, the code they share |
| `examples/`, `tests/` | the four examples and the headless test suite |
| `distro/` | the distribution: kernel, init, login, palm, the installer, recipes, images |
| `docs/` | design documents and the screenshots the README shows |
| `site/` | this site |
| `TODO.md` | what is not done, in the order it is worth doing |

## How work is split

Most of this repository was built by several agents working at once, each owning one directory. The rules they follow are written once, at the top of `TODO.md`, so that any prompt there can be handed over without more context. They are worth following by hand too:

::include{file="TODO.md" section="How to use a prompt from this file" depth=3}

Each area of the distribution keeps a notes file in `distro/notes/`, with the decisions its contract left open, what it asks of other areas, and what it verified. Those notes are published here under [Engineering notes](/distro/notes-integrate).

## Testing a change

| Command | What it checks |
| --- | --- |
| `make check` | the toolkit and the tests type-check |
| `make test` | the toolkit's headless test suite |
| `make -C distro test` | the disk image boots and works, driven over QMP in QEMU |
| `make -C distro test-installer` | the installer's self-tests |
| `make -C distro test-install` | a graphical and a command-line install in QEMU, each booted afterwards |
| `make -C distro check-libs` | no shipped binary needs more than libc, libm and the loader |

A claim in a document should come from running the command next to it. `TODO.md` explains why: one session found five of its claims false at once.

## This site

The site is a React Router app in `site/`, prerendered to static files. The toolkit pages (`/docs`, `/components`, `/apps`) are written for the site. The distribution pages and the generated reference are not: they are the repository's own Markdown and source, pulled in by a sync script, so that they say what the repository says.

```sh
cd site
npm install
npm run sync         # repository Markdown and source -> app/content/generated
npm run dev          # http://localhost:5173
npm run build        # sync, prerender every page, sitemap, search index, OG images
npm run check:links  # crawl the built site; fail on any broken link or anchor
```

`site/content/manifest.mjs` lists every synced page and the file, or the section of a file, it comes from. To publish a new document, add it there; to change what a page says, change the source document, not the site. `npm run sync -- --check` fails when the committed output is older than the sources.
