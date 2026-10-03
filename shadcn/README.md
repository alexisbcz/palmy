# shadcn widgets for palmy

Every shadcn/ui component, written with palmy primitives and measured against
Chromium rendering the real React source — see `../parity`. 182 cases, median
pixel error 1.79/255, zero geometry mismatches.

Use it with a collection:

```sh
odin build myapp \
  -collection:palmy=/home/alex/Work/palmy/palmy \
  -collection:shadcn=/home/alex/Work/palmy/shadcn
```

```odin
import p "palmy:."
import sc "shadcn:."

sc.register_shadcn_theme()   // once, before the first frame
p.set_text_gamma(1.8)        // the calibration measured against Chromium

sc.button(ui, "Save", .Default)
sc.badge(ui, "New", .Secondary)
sc.input(ui, value, "Search")
```

The theme registers palmy design tokens, so class strings read like the TSX:
`bg-primary`, `text-muted-foreground`, `border-input`, `rounded-lg`, `ring-3`.

Widgets take an explicit `State{hover, focus, disabled, invalid}` rather than
reading pseudo-classes, so a caller decides when they apply — drive it from
palmy's `is_hovered` / `focused` for live interaction.
