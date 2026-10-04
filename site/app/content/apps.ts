/**
 * The applications under `apps/`. Descriptions are drawn from each app's own
 * source — its `main.odin` header, its README where it has one, and the code
 * itself — not from the names.
 */

export type AppCategory =
  | "Desktop shell"
  | "Files & system"
  | "Communication"
  | "Media"
  | "Productivity"
  | "Creative"
  | "Developer"
  | "AI"
  | "Utilities";

export type AppEntry = {
  slug: string;
  name: string;
  summary: string;
  category: AppCategory;
  /** One clause worth knowing, verifiable in the source. */
  note?: string;
  /** This app records a scripted demo on a private headless compositor. */
  demo: boolean;
  /** Headless by construction: no window, so no recording. */
  headless?: boolean;
};

export const CATEGORIES: AppCategory[] = [
  "Desktop shell",
  "Files & system",
  "Communication",
  "Media",
  "Productivity",
  "Creative",
  "Developer",
  "AI",
  "Utilities",
];

export const APPS: AppEntry[] = [
  {
    slug: "wm",
    name: "wm",
    summary:
      "A floating, stacking window manager that is itself a Wayland compositor — it serves wl_compositor, wl_shm, wl_seat and xdg-shell while running as an ordinary window on the host.",
    category: "Desktop shell",
    note: "Implements the Wayland protocol server-side in proto.odin; client shm buffers are mapped and read straight out of the pool, with no toolkit library in between.",
    demo: true,
  },
  {
    slug: "launcher",
    name: "launcher",
    summary:
      "A dmenu/rofi-class application launcher that indexes real .desktop files and ranks them with a fuzzy matcher.",
    category: "Desktop shell",
    note: "Opens as a wlr-layer-shell overlay with exclusive keyboard focus, and carries a full context menu on the selected entry.",
    demo: true,
  },
  {
    slug: "greeter",
    name: "greeter",
    summary:
      "A greetd login greeter opened as an exclusive-focus layer-shell overlay, showing the machine's real accounts, sessions and hostname.",
    category: "Desktop shell",
    note: "Session power actions are deliberately stubbed, so a demo script can never actually reboot the machine.",
    demo: true,
  },

  {
    slug: "files",
    name: "files",
    summary:
      "A file browser held to Finder's standard: sidebar, sortable list view, icon grid, breadcrumbs and live filtering.",
    category: "Files & system",
    note: "Context menus are drawn inside the window, because xdg_popup is not implemented.",
    demo: true,
  },
  {
    slug: "archive",
    name: "archive",
    summary:
      "An archive browser, extractor and builder over bsdtar that decides what it is and is not allowed to do to the filesystem.",
    category: "Files & system",
    note: "Every entry name is checked for absolute paths, `..` traversal and symlinks before extraction is offered.",
    demo: true,
  },
  {
    slug: "sysmon",
    name: "sysmon",
    summary:
      "A system monitor that reads every number it shows straight out of /proc and /sys.",
    category: "Files & system",
    note: "No subprocess anywhere in the program; a stuck NFS mount is reported rather than allowed to hang the UI.",
    demo: true,
  },
  {
    slug: "network",
    name: "network",
    summary:
      "A NetworkManager front end showing interfaces, addressing and a live Wi-Fi scan, entirely keyboard-driven.",
    category: "Files & system",
    note: "Every figure comes from parsing `nmcli -t` on a worker thread; the destructive operations are routed through a logged intent that executes nothing.",
    demo: true,
  },
  {
    slug: "bluetooth",
    name: "bluetooth",
    summary:
      "A Bluetooth settings panel driven by bluetoothctl and rfkill, with scanning on a worker thread so the window never stalls.",
    category: "Files & system",
    demo: true,
  },
  {
    slug: "mixer",
    name: "mixer",
    summary:
      "An audio mixer panel driven by pactl and wpctl, with per-sink and per-stream volume.",
    category: "Files & system",
    note: "Every volume write is read back with `wpctl get-volume`, so the UI shows what the server actually did, and volume is capped at 1.0.",
    demo: true,
  },
  {
    slug: "power",
    name: "power",
    summary:
      "A power and session applet showing uptime, sessions, CPU frequency policy, thermal state and whatever upower reports.",
    category: "Files & system",
    note: "Lock, reboot and shutdown are wired to a stub that only logs what it would have run.",
    demo: true,
  },
  {
    slug: "torrent",
    name: "torrent",
    summary:
      "A BitTorrent client — bencode, the peer wire protocol, BEP 15 UDP trackers and piece hashing — that is loopback-only by construction.",
    category: "Files & system",
    note: "Every outbound connection passes a gate that refuses anything outside 127.0.0.0/8; there is no DNS resolution, no DHT, no PEX and no UPnP.",
    demo: true,
  },

  {
    slug: "mail",
    name: "mail",
    summary:
      "A mail client — folder sidebar, threaded list, reader, composer, search — over a local Maildir, with the protocol engine living in a separate program.",
    category: "Communication",
    note: "There is no network code in the binary at all: Send writes into the account's own Outbox Maildir, and the reader strips remote resources, so there is no tracking-pixel loader to exploit.",
    demo: true,
  },
  {
    slug: "mailcore",
    name: "mailcore",
    summary:
      "The engine half of the mail stack: a pure-Odin IMAP4rev1 client with IDLE and STARTTLS, plus JMAP, POP3, SMTP and Maildir storage, driven entirely from the command line.",
    category: "Communication",
    note: "IMAP is parsed by a real parser rather than line by line, because a `{N}` literal may contain raw CRLF that a line-splitting reader would mis-frame. Restricted to 127.0.0.0/8.",
    demo: false,
    headless: true,
  },
  {
    slug: "chat",
    name: "chat",
    summary:
      "A team chat client speaking a custom protocol to a real local server, so two instances on one machine are genuinely two clients talking to each other.",
    category: "Communication",
    note: "A length-prefixed JSON wire protocol with a broadcast ordering guarantee, documented in PROTOCOL.md; the server binds 127.0.0.1 only.",
    demo: true,
  },
  {
    slug: "call",
    name: "call",
    summary:
      "Real-time audio and video calling: two local instances dial each other over UDP and exchange captured, encoded, fragmented media.",
    category: "Communication",
    note: "Its own RTP-shaped protocol with a fixed 24-byte header and a microsecond timestamp from the same monotonic clock on both ends, so one-way delay is a subtraction rather than a guess.",
    demo: true,
  },

  {
    slug: "video",
    name: "video",
    summary:
      "A video player where ffmpeg decodes and hands raw frames over a pipe for the app to blit, with audio going out through pw-cat.",
    category: "Media",
    note: "The audio clock — the bytes pw-cat has accepted — is the master clock the picture is scheduled against.",
    demo: true,
  },
  {
    slug: "audio",
    name: "audio",
    summary:
      "A gapless music player where ffmpeg decodes, pw-cat plays, and the waveform, spectrum and oscilloscope are drawn from the real decoded samples.",
    category: "Media",
    note: "The next track's decoder and analysis start two seconds before the boundary, so playback never gaps.",
    demo: true,
  },
  {
    slug: "image",
    name: "image",
    summary:
      "An image viewer that opens a file with the rest of its folder as a thumbnail strip, or a library of recently-viewed pictures when opened with nothing.",
    category: "Media",
    note: "Zoom, pan and rotate are implemented against the raw pixel buffer rather than the image widget; decoding runs on a worker thread.",
    demo: true,
  },
  {
    slug: "reader",
    name: "reader",
    summary:
      "An e-book and document reader handling EPUB, MOBI, PDF and DjVu in one app, with EPUB reflow and fixed-page modes each exposing the controls appropriate to them.",
    category: "Media",
    note: "EPUB inflate goes through core:compress/zlib rather than a bundled library; 455 headless assertions in its selftest.",
    demo: false,
  },
  {
    slug: "captions",
    name: "captions",
    summary:
      "Local speech-to-text and a caption editor built around whisper.cpp with ffmpeg for media, and no network calls.",
    category: "Media",
    note: "Keyboard-only by design, with every blocking operation on a worker thread.",
    demo: true,
  },

  {
    slug: "docs",
    name: "docs",
    summary:
      "A word processor with styled runs inside paragraphs, A4 pagination, cross-paragraph caret and selection, and coalescing undo.",
    category: "Productivity",
    note: "Writes structured .docx, .odt, .rtf and PDF from scratch — including its own ZIP/OPC writer — and reads .docx back.",
    demo: true,
  },
  {
    slug: "sheets",
    name: "sheets",
    summary:
      "A spreadsheet with its own formula engine: tokenizer, parser, evaluator and the coercion rules a spreadsheet actually needs.",
    category: "Productivity",
    note: "The engine is separate from the grid, so `--selftest` runs the whole test suite headlessly; reads and writes real .xlsx.",
    demo: true,
  },
  {
    slug: "slides",
    name: "slides",
    summary:
      "A presentation editor with a slide sorter, canvas and inspector, plus a fullscreen presenter overlay in the same process.",
    category: "Productivity",
    note: "Exports an editable .pptx (OPC/PresentationML, EMU units) that opens cleanly in PowerPoint, Keynote and Impress.",
    demo: true,
  },
  {
    slug: "notes",
    name: "notes",
    summary:
      "A notebook that stores one real Markdown file per note, titled by its first line.",
    category: "Productivity",
    note: "Deliberately plain text, so the notes directory stays browsable and editable with any other tool.",
    demo: true,
  },
  {
    slug: "calendar",
    name: "calendar",
    summary: "A month-grid and year-view calendar with real events.",
    category: "Productivity",
    note: "Dates come from first-principles civil-date and ISO-week integer arithmetic rather than from `cal` or a timezone database.",
    demo: true,
  },
  {
    slug: "money",
    name: "money",
    summary:
      "A personal banking and budgeting app that imports real bank statement files, with no network code, no open-banking flow and no password field anywhere.",
    category: "Productivity",
    note: "Hand-parses ISO 20022 CAMT.053 XML and the unclosed-tag SGML dialect of OFX/QFX, including the credit/debit sign handling that breaks naive importers.",
    demo: true,
  },
  {
    slug: "maps",
    name: "maps",
    summary:
      "A vector map application: pan and zoom over rendered data, place search, and A* turn-by-turn routing.",
    category: "Productivity",
    note: "The road graph is CSR adjacency over vertices quantised to 1e-7 degrees, built from GeoJSON and OSM-XML readers, drawn by a from-scratch scanline rasterizer.",
    demo: true,
  },
  {
    slug: "shop",
    name: "shop",
    summary:
      "A price-comparison application across clothing and grocery retailers.",
    category: "Productivity",
    note: "Imports Google Merchant Center's RSS product feed rather than scraping, and the bundled catalogue is labelled synthetic everywhere it is shown or exported.",
    demo: true,
  },

  {
    slug: "photoshop",
    name: "photoshop",
    summary:
      "A layered raster image editor — brush, adjustments, filters, undo, colour picker — built entirely on the software rasterizer with no GPU and no texture upload.",
    category: "Creative",
    note: "Separable Gaussian blur, unsharp mask, Sobel and emboss are all implemented from scratch.",
    demo: true,
  },
  {
    slug: "videoedit",
    name: "videoedit",
    summary:
      "A non-linear video editor with four dedicated worker threads — import, preview decode, export and the mixer pump — so the frame loop never blocks on ffmpeg.",
    category: "Creative",
    note: "The preview playhead is read off the PCM byte count the sink has accepted rather than wall time, so picture and sound do not drift.",
    demo: true,
  },

  {
    slug: "editor",
    name: "editor",
    summary:
      "A text editor with a line-array buffer and a real tokenizing Odin syntax highlighter, fully reachable from the keyboard through a command palette.",
    category: "Developer",
    note: "The highlighter is a genuine tokenizer, not a pile of regular expressions.",
    demo: true,
  },
  {
    slug: "pickdemo",
    name: "pickdemo",
    summary:
      "A minimal harness that exposes the shared file picker on its own, behind four buttons.",
    category: "Developer",
    note: "Exists so the picker can be exercised, recorded and selftested without a host application behind it.",
    demo: true,
  },

  {
    slug: "ai",
    name: "ai",
    summary:
      "A desktop client for locally-running models that only ever talks to a loopback address — no remote endpoint exists in the binary — storing conversations and a prompt library as plain text.",
    category: "AI",
    note: "A hand-rolled HTTP/1.1 client with chunked and NDJSON framing, with the socket kept entirely off the UI thread.",
    demo: true,
  },
  {
    slug: "chatbot",
    name: "chatbot",
    summary:
      "A separate process that joins the chat server as an ordinary client and answers mentions by streaming a reply into a message it keeps editing.",
    category: "AI",
    note: "A single-threaded loop alternating between two sockets, which is why nothing in the program needs a mutex.",
    demo: true,
  },

  {
    slug: "calc",
    name: "calc",
    summary:
      "An expression calculator on a real tokenizer and recursive-descent parser, with precedence, parentheses, functions, constants and variables.",
    category: "Utilities",
    note: "The expression engine is independent of the UI and keyboard handling.",
    demo: true,
  },
  {
    slug: "vault",
    name: "vault",
    summary:
      "A password manager: a locked screen, a searchable list, a generator and counting-down TOTP codes.",
    category: "Utilities",
    note: "Argon2id for key derivation and an AEAD for the body with the header bound into the tag; decryption is all-or-nothing, so a failed tag never returns partial plaintext.",
    demo: true,
  },
  {
    slug: "clipboard",
    name: "clipboard",
    summary:
      "A clipboard history manager built around finding and restoring old entries, and around trusting what is stored.",
    category: "Utilities",
    note: "Selections flagged with a password-manager hint are never read at all, and every history file is written mode 0600.",
    demo: true,
  },
  {
    slug: "screenshot",
    name: "screenshot",
    summary:
      "A screenshot tool over grim and slurp that decodes and shows the PNG it actually captured before you decide to keep it.",
    category: "Utilities",
    note: "Captures land in a temporary directory first; the original is deleted when the window closes.",
    demo: true,
  },
  {
    slug: "colorpick",
    name: "colorpick",
    summary:
      "A keyboard-driven colour picker that samples pixels off the screen and checks text legibility against the chosen colour.",
    category: "Utilities",
    note: "There is no pointer-grab protocol available, so screen picking uses a keyboard-driven magnifier rather than a cursor grab.",
    demo: true,
  },
  {
    slug: "emoji",
    name: "emoji",
    summary:
      "A character picker — not an emoji picker — covering 2,753 characters that actually render with the fonts present.",
    category: "Utilities",
    note: "The character set is generated from the intersection of the Unicode Character Database with a font's cmap, because the available colour emoji font has no outline glyphs to rasterize.",
    demo: true,
  },
];

export const APP_COUNT = APPS.length;

export function appsByCategory(): { category: AppCategory; apps: AppEntry[] }[] {
  return CATEGORIES.map((category) => ({
    category,
    apps: APPS.filter((a) => a.category === category),
  })).filter((g) => g.apps.length > 0);
}
