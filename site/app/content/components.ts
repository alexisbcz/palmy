import parity from "./parity-data.json";

/**
 * Every component the shadcn CLI installs, and what the Odin side of this
 * project actually does about it.
 *
 * `status` is about behaviour, not pixels. All sixty-one are implemented as
 * widgets in the Odin layer and all of them are measured against Chromium
 * rendering the real React source. What differs is how much of the component
 * the widget owns:
 *
 *   built    the widget is a widget: hand it state and it is usable in an app.
 *   partial  it renders, but a named piece of the behaviour belongs to the
 *            caller — overlay placement, or a geometry pinned to the captured
 *            case.
 *   absent   not implemented at all. There are none; the field exists so the
 *            site can say so rather than implying it by omission.
 */
export type ComponentStatus = "built" | "partial" | "absent";

/** Why a component is only partial. Rendered as a standard explanation. */
export type GapKind = "overlay" | "fixture" | "input";

export type ComponentEntry = {
  slug: string;
  title: string;
  blurb: string;
  status: ComponentStatus;
  /** Path of the Odin source, relative to the repository root. */
  odinFile: string;
  /** Set when several components share one Odin file. */
  sharedWith?: string[];
  gap?: { kind: GapKind; detail: string };
  /** The Odin that produces it. */
  odin: string;
  /** The React equivalent, for comparison. */
  react: string;
  /** Not part of the public shadcn/ui docs set, but the CLI installs it. */
  extra?: boolean;
};

export const GAP_TEXT: Record<GapKind, string> = {
  overlay:
    "palmy does not implement xdg_popup, so there is no second surface to put a floating panel on. The widget draws the panel; the application places it inside the window as an absolutely positioned overlay with a z- class. That is a real constraint of the toolkit, not an oversight in the widget.",
  fixture:
    "The widget reproduces the geometry of the case the parity rig measures, because that capture is the specification it was calibrated against. The dynamic part — the data, the scroll position, the month — is the application's to supply.",
  input:
    "The visual parts are complete, but the caret, selection and focus behaviour are not owned by the widget. palmy's own text_field is the single-line input primitive; anything richer is the application's model.",
};

export const COMPONENTS: ComponentEntry[] = [
  {
    slug: "accordion",
    title: "Accordion",
    blurb:
      "A vertically stacked set of headings that each reveal a section of content.",
    status: "built",
    odinFile: "shadcn/accordion.odin",
    odin: `open := p.state(ui, "open", 0)

for item, i in items {
	p.key(ui, item.id)
	if sc.accordion_item(ui, item.label, item.body, open^ == i, i == len(items) - 1) {
		open^ = open^ == i ? -1 : i
	}
}`,
    react: `<Accordion>
  <AccordionItem value="one">
    <AccordionTrigger>Is it accessible?</AccordionTrigger>
    <AccordionContent>Yes.</AccordionContent>
  </AccordionItem>
</Accordion>`,
  },
  {
    slug: "alert",
    title: "Alert",
    blurb: "A callout for something the user should read before moving on.",
    status: "built",
    odinFile: "shadcn/alert.odin",
    odin: `sc.alert_open(ui, .Default, with_icon = true)
defer sc.alert_end(ui)

sc.alert_icon(ui, sc.ICON_TERMINAL)
sc.alert_body_open(ui, with_icon = true)
defer sc.alert_body_end(ui)

sc.alert_title(ui, "Heads up")
sc.alert_description(ui, "You can add components to your app.", .Default)`,
    react: `<Alert>
  <Terminal />
  <AlertTitle>Heads up</AlertTitle>
  <AlertDescription>You can add components to your app.</AlertDescription>
</Alert>`,
  },
  {
    slug: "alert-dialog",
    title: "Alert Dialog",
    blurb: "A modal that interrupts and expects an answer before it closes.",
    status: "partial",
    odinFile: "shadcn/alert_dialog.odin",
    gap: {
      kind: "overlay",
      detail:
        "There is no modal surface and no backdrop primitive. The dialog is a child of the window, drawn last, over a full-bleed scrim the application adds.",
    },
    odin: `// drawn last in the frame so it paints over everything
p.div(ui, "absolute inset-0 z-50 bg-black/50 items-center justify-center")
defer p.end(ui)

sc.alert_dialog_content_open(ui)
defer p.end(ui)

sc.alert_dialog_header_open(ui, centered = false)
sc.alert_dialog_title(ui, "Are you sure?")
sc.alert_dialog_description(ui, "This cannot be undone.")
p.end(ui)`,
    react: `<AlertDialog>
  <AlertDialogTrigger>Delete</AlertDialogTrigger>
  <AlertDialogContent>
    <AlertDialogTitle>Are you sure?</AlertDialogTitle>
    <AlertDialogDescription>This cannot be undone.</AlertDialogDescription>
  </AlertDialogContent>
</AlertDialog>`,
  },
  {
    slug: "aspect-ratio",
    title: "Aspect Ratio",
    blurb: "A box that keeps a fixed width-to-height ratio.",
    status: "built",
    odinFile: "shadcn/aspect_ratio.odin",
    odin: `sc.aspect_ratio(ui, 320, 16.0 / 9.0, "bg-muted rounded-lg")`,
    react: `<AspectRatio ratio={16 / 9}>
  <img src={src} alt="" className="rounded-lg object-cover" />
</AspectRatio>`,
  },
  {
    slug: "attachment",
    title: "Attachment",
    blurb: "A file chip with an icon, a name, a size and an action slot.",
    status: "built",
    odinFile: "shadcn/attachment.odin",
    extra: true,
    odin: `sc.attachment_open(ui, {size = .Default})
defer sc.attachment_end(ui)

sc.attachment_media(ui, sc.ICON_FILE_TEXT)
sc.attachment_content(ui, "report.pdf", "1.2 MB")
sc.attachment_actions(ui)`,
    react: `<Attachment>
  <AttachmentMedia><FileText /></AttachmentMedia>
  <AttachmentContent name="report.pdf" size="1.2 MB" />
</Attachment>`,
  },
  {
    slug: "avatar",
    title: "Avatar",
    blurb: "A round image with initials behind it when the image is missing.",
    status: "built",
    odinFile: "shadcn/avatar.odin",
    odin: `sc.avatar(ui, "AB", .Default, ringed = false)

// or a stack
sc.avatar_group_open(ui)
sc.avatar(ui, "AB")
sc.avatar(ui, "CD")
sc.avatar_group_count(ui, "+3")
sc.avatar_group_end(ui)`,
    react: `<Avatar>
  <AvatarImage src={src} />
  <AvatarFallback>AB</AvatarFallback>
</Avatar>`,
  },
  {
    slug: "badge",
    title: "Badge",
    blurb: "A small label for a status or a count.",
    status: "built",
    odinFile: "shadcn/badge.odin",
    odin: `sc.badge(ui, "Default", .Default)
sc.badge(ui, "Secondary", .Secondary)
sc.badge(ui, "Destructive", .Destructive)
sc.badge(ui, "Outline", .Outline)

sc.badge_icon(ui, "Verified", sc.ICON_BADGE_CHECK, .Secondary)`,
    react: `<Badge>Default</Badge>
<Badge variant="secondary">Secondary</Badge>
<Badge variant="destructive">Destructive</Badge>
<Badge variant="outline">Outline</Badge>`,
  },
  {
    slug: "breadcrumb",
    title: "Breadcrumb",
    blurb: "The path to the current page, with the last segment not a link.",
    status: "built",
    odinFile: "shadcn/breadcrumb.odin",
    odin: `sc.breadcrumb_open(ui)
defer sc.breadcrumb_close(ui)

sc.breadcrumb_link(ui, "Home")
sc.breadcrumb_separator(ui)
sc.breadcrumb_ellipsis(ui)
sc.breadcrumb_separator(ui)
sc.breadcrumb_page(ui, "Components")`,
    react: `<Breadcrumb>
  <BreadcrumbList>
    <BreadcrumbItem><BreadcrumbLink href="/">Home</BreadcrumbLink></BreadcrumbItem>
    <BreadcrumbSeparator />
    <BreadcrumbItem><BreadcrumbPage>Components</BreadcrumbPage></BreadcrumbItem>
  </BreadcrumbList>
</Breadcrumb>`,
  },
  {
    slug: "bubble",
    title: "Bubble",
    blurb: "A chat bubble, aligned to either end, with a reactions row.",
    status: "built",
    odinFile: "shadcn/bubble.odin",
    extra: true,
    odin: `sc.bubble_open(ui, align_end = true)
defer sc.bubble_end(ui)

sc.bubble_content(ui, "On my way", .Default, align_end = true)`,
    react: `<Bubble align="end">
  <BubbleContent>On my way</BubbleContent>
</Bubble>`,
  },
  {
    slug: "button",
    title: "Button",
    blurb: "The one every other component is measured against.",
    status: "built",
    odinFile: "shadcn/button.odin",
    odin: `// the convenience form
if sc.button(ui, "Save", .Default, .Default, {}) { save() }

// the form every application in this repository actually uses, because
// the label is usually an icon and a string rather than a string
idx := sc.button_open(ui, .Outline, .Default, sc.State{
	hover    = p.is_hovered(ui),
	focus    = p.focused(ui),
	disabled = busy,
})
p.icon(ui, sc.ICON_DOWNLOAD, "size-4")
p.text(ui, "Download")
sc.button_end(ui)
if p.activated(ui, idx) { download() }`,
    react: `<Button>Save</Button>
<Button variant="outline">
  <Download /> Download
</Button>`,
  },
  {
    slug: "button-group",
    title: "Button Group",
    blurb: "Buttons joined into one control, with the seams between them.",
    status: "built",
    odinFile: "shadcn/button_group.odin",
    odin: `sc.button_group_open(ui, vertical = false)
defer sc.button_group_close(ui)

sc.button_group_button(ui, "Left")
sc.button_group_separator(ui)
sc.button_group_button(ui, "Right")`,
    react: `<ButtonGroup>
  <Button variant="outline">Left</Button>
  <Button variant="outline">Right</Button>
</ButtonGroup>`,
  },
  {
    slug: "calendar",
    title: "Calendar",
    blurb: "A month grid for picking a date or a range.",
    status: "partial",
    odinFile: "shadcn/calendar.odin",
    gap: {
      kind: "fixture",
      detail:
        "The grid is pinned to a month that begins on a Sunday, so it is exactly five rows of seven and the snapped browser boxes and the palmy boxes coincide. It is a rendering of the measured case, not a date picker. The arithmetic for a real one exists in the calendar application, which computes civil dates and ISO weeks from integers.",
    },
    odin: `sc.calendar(ui, .Single)`,
    react: `<Calendar mode="single" selected={date} onSelect={setDate} />`,
  },
  {
    slug: "card",
    title: "Card",
    blurb: "A panel with a header, a body and a footer.",
    status: "built",
    odinFile: "shadcn/card.odin",
    odin: `sc.card_open(ui)
defer sc.card_end(ui)

sc.card_header_open(ui)
sc.card_title(ui, "Create project")
sc.card_description(ui, "Deploy your new project in one click.")
sc.card_header_end(ui)

sc.card_content(ui, "…")

sc.card_footer_open(ui)
sc.card_footer_end(ui)`,
    react: `<Card>
  <CardHeader>
    <CardTitle>Create project</CardTitle>
    <CardDescription>Deploy your new project in one click.</CardDescription>
  </CardHeader>
  <CardContent>…</CardContent>
  <CardFooter />
</Card>`,
  },
  {
    slug: "carousel",
    title: "Carousel",
    blurb: "A horizontal track of slides with previous and next controls.",
    status: "partial",
    odinFile: "shadcn/carousel.odin",
    gap: {
      kind: "fixture",
      detail:
        "The track is built and clipped correctly, so the first slide fills the viewport and the rest are off the edge, but nothing scrolls: there is no drag or momentum in the widget. An application that wants a moving carousel animates the track's offset itself.",
    },
    odin: `sc.carousel(ui, []string{"1", "2", "3", "4", "5"})`,
    react: `<Carousel>
  <CarouselContent>
    {items.map((i) => <CarouselItem key={i}>{i}</CarouselItem>)}
  </CarouselContent>
  <CarouselPrevious />
  <CarouselNext />
</Carousel>`,
  },
  {
    slug: "chart",
    title: "Chart",
    blurb: "Bars, lines, a grid, ticks and a legend.",
    status: "partial",
    odinFile: "shadcn/chart.odin",
    gap: {
      kind: "fixture",
      detail:
        "The React component wraps a charting library that emits SVG, so there was nothing to translate class for class and the capture's own geometry became the specification: the scales, the band widths and the tick count are read off the measured output. Bars and grid lines are ordinary boxes so the rasterizer handles their corners; the line chart's polylines go through a raw pixel callback, because a diagonal stroke is not a box.",
    },
    odin: `sc.chart_open(ui)
defer sc.chart_end(ui)

sc.chart_grid(ui)
sc.chart_bars(ui, values)
sc.chart_legend_item(ui, "Desktop")`,
    react: `<ChartContainer config={config}>
  <BarChart data={data}>
    <CartesianGrid vertical={false} />
    <Bar dataKey="desktop" radius={4} />
  </BarChart>
</ChartContainer>`,
  },
  {
    slug: "checkbox",
    title: "Checkbox",
    blurb: "On, off, or indeterminate.",
    status: "built",
    odinFile: "shadcn/checkbox.odin",
    odin: `// the shadcn-styled box: state in, pixels out
sc.checkbox(ui, done ? .On : .Off, sc.State{focus = p.focused(ui)})

// palmy's own widget, which owns the boolean and the label
p.checkbox(ui, "Accept terms", &accepted)`,
    react: `<Checkbox checked={done} onCheckedChange={setDone} />`,
  },
  {
    slug: "collapsible",
    title: "Collapsible",
    blurb: "A panel that opens and closes.",
    status: "built",
    odinFile: "shadcn/collapsible.odin",
    odin: `open := p.state(ui, "open", false)
if sc.collapsible(ui, "Starred repositories", "@palmy/ui", open^) {
	open^ = !open^
}`,
    react: `<Collapsible>
  <CollapsibleTrigger>Starred repositories</CollapsibleTrigger>
  <CollapsibleContent>@palmy/ui</CollapsibleContent>
</Collapsible>`,
  },
  {
    slug: "combobox",
    title: "Combobox",
    blurb: "An input that filters a list, with chips for multiple selections.",
    status: "partial",
    odinFile: "shadcn/combobox.odin",
    gap: {
      kind: "overlay",
      detail:
        "The popup is drawn in the window. The filtering itself is a few lines over your own slice, and the input is palmy's text_field.",
    },
    odin: `query := p.state(ui, "q", [dynamic]u8{})

sc.combobox_chips_open(ui)
for tag in chosen { sc.combobox_chip(ui, tag) }
sc.combobox_chips_input(ui, string(query[:]))
p.end(ui)

// the popup, positioned by you
sc.combobox_content_open(ui)
sc.combobox_list_open(ui)
for opt in filtered { sc.combobox_item(ui, opt, opt == current) }
if len(filtered) == 0 { sc.combobox_empty(ui, "No results.") }
p.end(ui)
p.end(ui)`,
    react: `<Combobox>
  <ComboboxInput placeholder="Search…" />
  <ComboboxContent>
    <ComboboxItem value="next">Next.js</ComboboxItem>
  </ComboboxContent>
</Combobox>`,
  },
  {
    slug: "command",
    title: "Command",
    blurb: "A filtered command list, usually in a dialog.",
    status: "partial",
    odinFile: "shadcn/command.odin",
    gap: {
      kind: "overlay",
      detail:
        "The list, the groups, the items and the shortcut column are all there. The dialog it normally lives in is an in-window overlay, and the matching is yours — the launcher application has a fuzzy matcher over real .desktop entries that does exactly this.",
    },
    odin: `sc.command_open(ui, ringed = true)
defer p.end(ui)

sc.command_input(ui, string(query[:]), "Type a command…")
sc.command_list_open(ui)
defer p.end(ui)

sc.command_group_open(ui)
sc.command_group_heading(ui, "Suggestions")
sc.command_items_open(ui)
for item, i in results {
	p.key(ui, item.id)
	idx := sc.command_item_open(ui, i == selected)
	sc.command_item_text(ui, item.label)
	sc.command_shortcut(ui, item.keys)
	p.end(ui)
	if p.activated(ui, idx) { run(item) }
}`,
    react: `<Command>
  <CommandInput placeholder="Type a command…" />
  <CommandList>
    <CommandGroup heading="Suggestions">
      <CommandItem>Calendar</CommandItem>
    </CommandGroup>
  </CommandList>
</Command>`,
  },
  {
    slug: "context-menu",
    title: "Context Menu",
    blurb: "A menu raised by the secondary pointer button.",
    status: "partial",
    odinFile: "shadcn/menu.odin",
    sharedWith: ["dropdown-menu"],
    gap: {
      kind: "overlay",
      detail:
        "Drawn inside the window at the pointer position you record. The file browser and the launcher both do this for real, with macOS-grade menus; the only thing they cannot do is escape the window's own bounds.",
    },
    odin: `at := p.state(ui, "menu_at", [2]f32{})

if p.clickable(ui, row) { /* … */ }

if menu_open^ {
	p.div(ui, "absolute z-50")
	p.style(ui).pos = at^
	sc.menu_content_open(ui)
	sc.menu_group_open(ui)
	sc.menu_label(ui, "Actions")
	if idx := sc.menu_item_open(ui); true {
		sc.menu_item_text(ui, "Open")
		sc.menu_shortcut(ui, "⏎")
		p.end(ui)
	}
	sc.menu_separator(ui)
	i2 := sc.menu_item_open(ui, destructive = true)
	sc.menu_item_text(ui, "Delete")
	p.end(ui)
	p.end(ui)
	p.end(ui)
}`,
    react: `<ContextMenu>
  <ContextMenuTrigger>Right click</ContextMenuTrigger>
  <ContextMenuContent>
    <ContextMenuItem>Open</ContextMenuItem>
  </ContextMenuContent>
</ContextMenu>`,
  },
  {
    slug: "dialog",
    title: "Dialog",
    blurb: "A modal window with a header, a body and a footer.",
    status: "partial",
    odinFile: "shadcn/dialog.odin",
    gap: {
      kind: "overlay",
      detail:
        "One window per process and no popup surface, so the dialog is a child drawn last over a scrim. Every application here that has a dialog does it this way.",
    },
    odin: `if open^ {
	p.div(ui, "absolute inset-0 z-50 bg-black/50 items-center justify-center")
	defer p.end(ui)

	sc.dialog_content_open(ui)
	defer p.end(ui)

	sc.dialog_header_open(ui)
	sc.dialog_title(ui, "Edit profile")
	sc.dialog_description(ui, "Make changes to your profile here.")
	p.end(ui)

	sc.dialog_footer_open(ui)
	if sc.filled_button(ui, "Save", "", .Default, .Default, {}) { save() }
	p.end(ui)

	sc.dialog_close_button(ui, 16, 8)
}`,
    react: `<Dialog>
  <DialogTrigger>Edit</DialogTrigger>
  <DialogContent>
    <DialogHeader>
      <DialogTitle>Edit profile</DialogTitle>
    </DialogHeader>
  </DialogContent>
</Dialog>`,
  },
  {
    slug: "direction",
    title: "Direction",
    blurb: "The right-to-left provider, whose only visible effect is on layout.",
    status: "partial",
    odinFile: "shadcn/direction.odin",
    extra: true,
    gap: {
      kind: "fixture",
      detail:
        "palmy's layout engine is left-to-right: there is no bidi and no direction-aware flexbox. The provider paints nothing in React either, so what is implemented is the one observable consequence — a slider whose fill and thumb end up on the other side — and it takes the measured positions as arguments rather than deriving them.",
    },
    odin: `sc.slider_rtl(ui, 1216, 367.19, 355.19)`,
    react: `<DirectionProvider direction="rtl">
  <Slider defaultValue={[30]} />
</DirectionProvider>`,
  },
  {
    slug: "drawer",
    title: "Drawer",
    blurb: "A panel that slides in from an edge.",
    status: "partial",
    odinFile: "shadcn/sheet.odin",
    sharedWith: ["sheet"],
    gap: {
      kind: "overlay",
      detail:
        "The panel for each of the four sides is built. Sliding it in is an animation over its offset, which palmy will redraw for you — `transition` eases colours, not positions, so the application moves the box.",
    },
    odin: `sc.drawer_content_open(ui, .Bottom)
defer p.end(ui)

sc.drawer_header_open(ui, centered = true)
sc.sheet_title(ui, "Move goal")
sc.sheet_description(ui, "Set your daily activity goal.")
p.end(ui)

sc.drawer_body_open(ui, .Bottom)
p.end(ui)
sc.drawer_footer_open(ui)
p.end(ui)`,
    react: `<Drawer>
  <DrawerTrigger>Open</DrawerTrigger>
  <DrawerContent>
    <DrawerHeader><DrawerTitle>Move goal</DrawerTitle></DrawerHeader>
  </DrawerContent>
</Drawer>`,
  },
  {
    slug: "dropdown-menu",
    title: "Dropdown Menu",
    blurb: "A menu anchored to the control that opened it.",
    status: "partial",
    odinFile: "shadcn/menu.odin",
    sharedWith: ["context-menu"],
    gap: {
      kind: "overlay",
      detail:
        "The menu popup, its groups, labels, check items, shortcut column and separators are all built. Where it goes is the application's, because there is no popup surface to anchor to — and `node_rect` on the trigger from the previous frame is how you find out where to put it.",
    },
    odin: `trigger := sc.button_open(ui, .Outline, .Default, {})
p.text(ui, "Open")
sc.button_end(ui)
if p.activated(ui, trigger) { open^ = !open^ }

if open^ {
	r := p.node_rect(ui, trigger)   // last frame's geometry
	p.div(ui, "absolute z-50")
	sc.menu_content_open(ui)
	sc.menu_label(ui, "My account")
	sc.menu_separator(ui)
	i := sc.menu_check_item_open(ui)
	sc.menu_indicator(ui)
	sc.menu_item_text(ui, "Status bar")
	p.end(ui)
	p.end(ui)
	p.end(ui)
}`,
    react: `<DropdownMenu>
  <DropdownMenuTrigger asChild><Button variant="outline">Open</Button></DropdownMenuTrigger>
  <DropdownMenuContent>
    <DropdownMenuLabel>My account</DropdownMenuLabel>
    <DropdownMenuCheckboxItem checked>Status bar</DropdownMenuCheckboxItem>
  </DropdownMenuContent>
</DropdownMenu>`,
  },
  {
    slug: "empty",
    title: "Empty",
    blurb: "The state a list is in before it has anything in it.",
    status: "built",
    odinFile: "shadcn/empty.odin",
    odin: `sc.empty_open(ui)
defer sc.empty_end(ui)

sc.empty_header_open(ui)
defer sc.empty_header_end(ui)

sc.empty_media_icon(ui, sc.ICON_SEARCH)
sc.empty_title(ui, "Scanning")
sc.empty_description(ui, "Nothing has advertised yet. This takes a few seconds.")`,
    react: `<Empty>
  <EmptyHeader>
    <EmptyMedia><Search /></EmptyMedia>
    <EmptyTitle>Scanning</EmptyTitle>
    <EmptyDescription>Nothing has advertised yet.</EmptyDescription>
  </EmptyHeader>
</Empty>`,
  },
  {
    slug: "field",
    title: "Field",
    blurb: "A label, a control, a description and an error, in the right order.",
    status: "built",
    odinFile: "shadcn/field.odin",
    odin: `sc.field_open(ui)
defer sc.field_end(ui)

sc.field_label(ui, "Email")
sc.input(ui, string(buf[:]), "you@example.com", sc.State{invalid = bad})
sc.field_description(ui, "We never share it.")
if bad { sc.field_error(ui, "That is not an address.") }`,
    react: `<Field>
  <FieldLabel>Email</FieldLabel>
  <Input placeholder="you@example.com" />
  <FieldDescription>We never share it.</FieldDescription>
</Field>`,
  },
  {
    slug: "hover-card",
    title: "Hover Card",
    blurb: "A panel that appears on hover rather than on click.",
    status: "partial",
    odinFile: "shadcn/popover.odin",
    sharedWith: ["popover", "tooltip"],
    gap: {
      kind: "overlay",
      detail:
        "The panel is built. The hover delay and the placement are the application's: palmy gives you `is_hovered` against the previous frame's geometry and `app_elapsed` for the dwell timer.",
    },
    odin: `card := p.div(ui, "relative")
p.text(ui, "@palmy", "underline")
if p.is_hovered(ui, card) {
	p.div(ui, "absolute top-6 left-0 z-50")
	sc.hover_card_content_open(ui)
	sc.avatar_fallback_sm(ui, "PY")
	p.text(ui, "The Palmframe UI toolkit.", "text-sm")
	p.end(ui)
	p.end(ui)
}
p.end(ui)`,
    react: `<HoverCard>
  <HoverCardTrigger>@palmy</HoverCardTrigger>
  <HoverCardContent>The Palmframe UI toolkit.</HoverCardContent>
</HoverCard>`,
  },
  {
    slug: "input",
    title: "Input",
    blurb: "A single-line text field.",
    status: "built",
    odinFile: "shadcn/input.odin",
    odin: `// the shadcn-styled box, drawn from a value you hold
sc.input(ui, string(buf[:]), "Email", sc.State{focus = p.focused(ui)})

// palmy's own editable field, which owns the caret and the keys
changed, submitted := p.text_field(ui, &buf, "Email")`,
    react: `<Input type="email" placeholder="Email" />`,
  },
  {
    slug: "input-group",
    title: "Input Group",
    blurb: "An input with an add-on, a button or a prefix fused to it.",
    status: "built",
    odinFile: "shadcn/input_group.odin",
    odin: `sc.input_group_open(ui)
defer sc.input_group_end(ui)

sc.ig_addon_open(ui)
p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground")
sc.ig_addon_end(ui)

sc.ig_input(ui, string(buf[:]), "Search…")

sc.ig_button_open(ui)
p.text(ui, "Go")
sc.ig_button_end(ui)`,
    react: `<InputGroup>
  <InputGroupAddon><Search /></InputGroupAddon>
  <InputGroupInput placeholder="Search…" />
  <InputGroupButton>Go</InputGroupButton>
</InputGroup>`,
  },
  {
    slug: "input-otp",
    title: "Input OTP",
    blurb: "A strip of single-character slots for a one-time code.",
    status: "partial",
    odinFile: "shadcn/input_otp.odin",
    gap: {
      kind: "input",
      detail:
        "The slots, their shared borders and the rounded ends are built from the source rather than from the capture, because the library stretches a hidden input over the whole strip and the measured box says nothing about the slots. Nothing is focused, so there is no active slot and no caret — an application wires those to its own buffer.",
    },
    odin: `sc.input_otp_open(ui)
defer sc.input_otp_end(ui)

sc.input_otp_group(ui, []string{"1", "2", "3"})
sc.input_otp_separator(ui)
sc.input_otp_group(ui, []string{"4", "5", "6"})`,
    react: `<InputOTP maxLength={6}>
  <InputOTPGroup>
    <InputOTPSlot index={0} />
  </InputOTPGroup>
  <InputOTPSeparator />
</InputOTP>`,
  },
  {
    slug: "item",
    title: "Item",
    blurb: "A row with media, a title, a description and actions.",
    status: "built",
    odinFile: "shadcn/item.odin",
    odin: `sc.item_open(ui, .Outline, .Default)
defer sc.item_end(ui)

sc.item_media_icon(ui, sc.ICON_FOLDER)
sc.item_content_open(ui)
sc.item_title(ui, "Documents")
sc.item_description(ui, "42 items")
sc.item_content_end(ui)
sc.item_actions_open(ui)
sc.item_actions_end(ui)`,
    react: `<Item variant="outline">
  <ItemMedia><Folder /></ItemMedia>
  <ItemContent>
    <ItemTitle>Documents</ItemTitle>
    <ItemDescription>42 items</ItemDescription>
  </ItemContent>
</Item>`,
  },
  {
    slug: "kbd",
    title: "Kbd",
    blurb: "A key, drawn as a key.",
    status: "built",
    odinFile: "shadcn/kbd.odin",
    odin: `sc.kbd_group_open(ui)
sc.kbd(ui, "Ctrl")
sc.kbd(ui, "K")
sc.kbd_group_end(ui)`,
    react: `<KbdGroup>
  <Kbd>Ctrl</Kbd>
  <Kbd>K</Kbd>
</KbdGroup>`,
  },
  {
    slug: "label",
    title: "Label",
    blurb: "A caption for a control.",
    status: "built",
    odinFile: "shadcn/label.odin",
    odin: `sc.label(ui, "Accept terms and conditions")`,
    react: `<Label htmlFor="terms">Accept terms and conditions</Label>`,
  },
  {
    slug: "marker",
    title: "Marker",
    blurb: "A rule with a label in it, or a label with rules either side.",
    status: "built",
    odinFile: "shadcn/marker.odin",
    extra: true,
    odin: `sc.marker_open(ui, .Separator)
defer sc.marker_end(ui)

sc.marker_line(ui)
sc.marker_content(ui, "Today")
sc.marker_line(ui)`,
    react: `<Marker variant="separator">Today</Marker>`,
  },
  {
    slug: "menubar",
    title: "Menubar",
    blurb: "A row of menu triggers, as an application's main menu.",
    status: "partial",
    odinFile: "shadcn/menubar.odin",
    gap: {
      kind: "overlay",
      detail:
        "The bar, the triggers and the popup content are built; the popup is drawn inside the window under the trigger you opened.",
    },
    odin: `sc.menubar_open(ui)
defer sc.menubar_close(ui)

for m, i in menus {
	p.key(ui, m.label)
	if sc.menubar_trigger(ui, m.label, open^ == i) { open^ = i }
	if open^ == i {
		sc.menubar_content_open(ui)
		sc.menubar_item(ui, "New window", "⌘N")
		sc.menubar_separator(ui)
		sc.menubar_item(ui, "Print", "⌘P")
		sc.menubar_content_close(ui)
	}
}`,
    react: `<Menubar>
  <MenubarMenu>
    <MenubarTrigger>File</MenubarTrigger>
    <MenubarContent>
      <MenubarItem>New window <MenubarShortcut>⌘N</MenubarShortcut></MenubarItem>
    </MenubarContent>
  </MenubarMenu>
</Menubar>`,
  },
  {
    slug: "message",
    title: "Message",
    blurb: "A chat message: avatar, content, caption, aligned to either end.",
    status: "built",
    odinFile: "shadcn/message.odin",
    extra: true,
    odin: `sc.message_open(ui, align_end = false)
defer sc.message_end(ui)

sc.message_avatar(ui, "AB")
sc.message_content_open(ui)
sc.bubble_content(ui, "Morning", .Muted)
sc.message_caption(ui, "09:14")
sc.message_content_end(ui)`,
    react: `<Message>
  <MessageAvatar>AB</MessageAvatar>
  <MessageContent>Morning</MessageContent>
</Message>`,
  },
  {
    slug: "message-scroller",
    title: "Message Scroller",
    blurb: "A bordered viewport that reserves a stable scrollbar gutter.",
    status: "built",
    odinFile: "shadcn/message_scroller.odin",
    extra: true,
    odin: `sc.message_scroller(ui, []string{"First", "Second", "Third"})`,
    react: `<MessageScroller>
  {items.map((m) => <div key={m}>{m}</div>)}
</MessageScroller>`,
  },
  {
    slug: "native-select",
    title: "Native Select",
    blurb: "The platform's own select control, styled to match.",
    status: "built",
    odinFile: "shadcn/native_select.odin",
    odin: `sc.native_select(ui, "Light", .Default, sc.State{focus = p.focused(ui)})`,
    react: `<NativeSelect>
  <option>Light</option>
  <option>Dark</option>
</NativeSelect>`,
  },
  {
    slug: "navigation-menu",
    title: "Navigation Menu",
    blurb: "A horizontal set of links with panels that open under them.",
    status: "partial",
    odinFile: "shadcn/navigation_menu.odin",
    gap: {
      kind: "overlay",
      detail:
        "The bar, the triggers, the panel and its links are built; the panel is positioned in the window.",
    },
    odin: `sc.navigation_menu_open(ui)
defer sc.navigation_menu_close(ui)

sc.navigation_menu_trigger(ui, "Getting started", open^)
if open^ {
	sc.navigation_menu_content_open(ui)
	sc.navigation_menu_link(ui, "Introduction", "Re-usable components.")
	sc.navigation_menu_content_close(ui)
}`,
    react: `<NavigationMenu>
  <NavigationMenuItem>
    <NavigationMenuTrigger>Getting started</NavigationMenuTrigger>
    <NavigationMenuContent>
      <NavigationMenuLink>Introduction</NavigationMenuLink>
    </NavigationMenuContent>
  </NavigationMenuItem>
</NavigationMenu>`,
  },
  {
    slug: "pagination",
    title: "Pagination",
    blurb: "Previous, next, page numbers, and an ellipsis where they are cut.",
    status: "built",
    odinFile: "shadcn/pagination.odin",
    odin: `sc.pagination_open(ui)
defer sc.pagination_close(ui)

sc.pagination_previous(ui)
sc.pagination_link(ui, "1", page^ == 1)
sc.pagination_link(ui, "2", page^ == 2)
sc.pagination_ellipsis(ui)
sc.pagination_next(ui)`,
    react: `<Pagination>
  <PaginationContent>
    <PaginationPrevious href="#" />
    <PaginationLink href="#" isActive>1</PaginationLink>
    <PaginationEllipsis />
    <PaginationNext href="#" />
  </PaginationContent>
</Pagination>`,
  },
  {
    slug: "popover",
    title: "Popover",
    blurb: "A floating panel anchored to a trigger.",
    status: "partial",
    odinFile: "shadcn/popover.odin",
    sharedWith: ["hover-card", "tooltip"],
    gap: {
      kind: "overlay",
      detail:
        "Popover, hover card and tooltip are the three plain floating panels and they share one file. All three are drawn inside the window.",
    },
    odin: `sc.popover_content_open(ui)
defer p.end(ui)

sc.popover_header_open(ui)
sc.popover_title(ui, "Dimensions")
sc.popover_description(ui, "Set the dimensions for the layer.")
p.end(ui)`,
    react: `<Popover>
  <PopoverTrigger>Open</PopoverTrigger>
  <PopoverContent>
    <h4>Dimensions</h4>
  </PopoverContent>
</Popover>`,
  },
  {
    slug: "progress",
    title: "Progress",
    blurb: "A determinate bar.",
    status: "built",
    odinFile: "shadcn/progress.odin",
    odin: `sc.progress_open(ui)
defer sc.progress_end(ui)

sc.progress_header(ui, "Uploading", "66%")
sc.progress_track(ui, 0.66)

// palmy's own one-liner
p.progress(ui, 0.66)`,
    react: `<Progress value={66} />`,
  },
  {
    slug: "questionnaire",
    title: "Questionnaire",
    blurb: "A fieldset of choices with a legend and a pair of actions.",
    status: "partial",
    odinFile: "shadcn/questionnaire.odin",
    extra: true,
    gap: {
      kind: "fixture",
      detail:
        "A legend is taken out of a fieldset's flow in CSS, which does not map onto flex, so it is built as a plain column. The previous and next buttons render nothing for a one-item questionnaire, which is what the measured case is, so the actions row is empty space in both captures.",
    },
    odin: `sc.questionnaire_legend(ui, "How did you hear about us?")
sc.questionnaire_choice(ui, "A friend", chosen^ == 0)
sc.questionnaire_choice(ui, "Search", chosen^ == 1)
sc.questionnaire_actions(ui)`,
    react: `<Questionnaire>
  <QuestionnaireLegend>How did you hear about us?</QuestionnaireLegend>
  <QuestionnaireChoice value="friend">A friend</QuestionnaireChoice>
</Questionnaire>`,
  },
  {
    slug: "radio-group",
    title: "Radio Group",
    blurb: "One of several.",
    status: "built",
    odinFile: "shadcn/radio_group.odin",
    odin: `sc.radio_group_open(ui)
defer sc.radio_group_end(ui)

for opt, i in options {
	p.key(ui, opt)
	row := p.row(ui, "items-center gap-2")
	sc.radio(ui, chosen^ == i, sc.State{focus = p.focused(ui)})
	sc.label(ui, opt)
	p.end(ui)
	if p.activated(ui, row) { chosen^ = i }
}`,
    react: `<RadioGroup defaultValue="comfortable">
  <RadioGroupItem value="default" /> <Label>Default</Label>
</RadioGroup>`,
  },
  {
    slug: "resizable",
    title: "Resizable",
    blurb: "Panels with a draggable divider between them.",
    status: "partial",
    odinFile: "shadcn/resizable.odin",
    gap: {
      kind: "fixture",
      detail:
        "The two panels, the handle and the grip are built, and the split is a fraction you pass in. Dragging it is yours: palmy gives you the pointer position and whether the button is down, so the handle's drag is about five lines, but the widget does not do it for you.",
    },
    odin: `split := p.state(ui, "split", f32(0.5))
sc.resizable_group(ui, .Horizontal, {"One", "Two"}, split^, true, 200)`,
    react: `<ResizablePanelGroup orientation="horizontal">
  <ResizablePanel defaultSize={50}>One</ResizablePanel>
  <ResizableHandle withHandle />
  <ResizablePanel defaultSize={50}>Two</ResizablePanel>
</ResizablePanelGroup>`,
  },
  {
    slug: "scroll-area",
    title: "Scroll Area",
    blurb: "A viewport with a styled scrollbar.",
    status: "partial",
    odinFile: "shadcn/scroll_area.odin",
    gap: {
      kind: "fixture",
      detail:
        "The widget draws the styled bar and takes the thumb height as an argument. Real scrolling is a palmy class rather than a widget: `overflow-scroll` on any element gives you wheel scrolling, a scrollbar painted by the renderer, and `scroll_into_view` to bring a row back.",
    },
    odin: `// the shadcn-styled bar
sc.scroll_area_open(ui, "h-72 w-48")
for tag in tags { p.text(ui, tag, "text-sm py-1") }
sc.scroll_area_end(ui, thumb_h = 48)

// or just let palmy scroll it
p.col(ui, "h-72 overflow-scroll gap-1")
for tag in tags { p.text(ui, tag, "text-sm") }
p.end(ui)`,
    react: `<ScrollArea className="h-72 w-48">
  {tags.map((t) => <div key={t}>{t}</div>)}
</ScrollArea>`,
  },
  {
    slug: "select",
    title: "Select",
    blurb: "A trigger that opens a list of options.",
    status: "partial",
    odinFile: "shadcn/select.odin",
    gap: {
      kind: "overlay",
      detail:
        "The trigger is a plain widget and works as one. The list is an in-window overlay, and it reuses the item geometry from the menu file, which is why the check indicator lives there.",
    },
    odin: `t := sc.select_trigger(ui, value^, "Select a fruit", false, sc.State{focus = p.focused(ui)})
if p.activated(ui, t) { open^ = !open^ }

if open^ {
	sc.select_content_open(ui)
	sc.select_list_open(ui)
	sc.select_group_open(ui)
	sc.select_label(ui, "Fruits")
	for f in fruits {
		p.key(ui, f)
		if sc.select_item(ui, f, f == value^) { value^ = f; open^ = false }
	}
	p.end(ui); p.end(ui); p.end(ui)
}`,
    react: `<Select>
  <SelectTrigger><SelectValue placeholder="Select a fruit" /></SelectTrigger>
  <SelectContent>
    <SelectGroup>
      <SelectLabel>Fruits</SelectLabel>
      <SelectItem value="apple">Apple</SelectItem>
    </SelectGroup>
  </SelectContent>
</Select>`,
  },
  {
    slug: "separator",
    title: "Separator",
    blurb: "A hairline, in either orientation.",
    status: "built",
    odinFile: "shadcn/separator.odin",
    odin: `sc.separator(ui, .Horizontal)
sc.separator(ui, .Vertical, "h-4")`,
    react: `<Separator />
<Separator orientation="vertical" />`,
  },
  {
    slug: "sheet",
    title: "Sheet",
    blurb: "A panel anchored to one edge of the window.",
    status: "partial",
    odinFile: "shadcn/sheet.odin",
    sharedWith: ["drawer"],
    gap: {
      kind: "overlay",
      detail:
        "The panel is built for all four sides. It is a child of the window drawn over a scrim, not a separate surface.",
    },
    odin: `sc.sheet_content_open(ui, .Right)
defer p.end(ui)

sc.sheet_header_open(ui)
sc.sheet_title(ui, "Edit profile")
sc.sheet_description(ui, "Make changes and save when you are done.")
p.end(ui)

sc.sheet_spacer(ui)
sc.sheet_footer_open(ui)
p.end(ui)`,
    react: `<Sheet>
  <SheetTrigger>Open</SheetTrigger>
  <SheetContent side="right">
    <SheetHeader><SheetTitle>Edit profile</SheetTitle></SheetHeader>
  </SheetContent>
</Sheet>`,
  },
  {
    slug: "sidebar",
    title: "Sidebar",
    blurb: "An application sidebar: header, groups, menus, submenus, footer.",
    status: "built",
    odinFile: "shadcn/sidebar.odin",
    odin: `sc.sidebar_open(ui, "h-full")
defer sc.sidebar_close(ui)

sc.sidebar_header_open(ui)
sc.sidebar_section_close(ui)

sc.sidebar_content_open(ui)
sc.sidebar_group_open(ui)
sc.sidebar_group_label(ui, "Platform")
sc.sidebar_group_content_open(ui)
sc.sidebar_menu_open(ui)
for item in items {
	p.key(ui, item.id)
	sc.sidebar_menu_item_open(ui)
	if sc.sidebar_menu_button(ui, item.label, item.icon, item.id == current^) {
		current^ = item.id
	}
	sc.sidebar_close_one(ui)
}`,
    react: `<Sidebar>
  <SidebarContent>
    <SidebarGroup>
      <SidebarGroupLabel>Platform</SidebarGroupLabel>
      <SidebarMenu>
        <SidebarMenuItem><SidebarMenuButton>Inbox</SidebarMenuButton></SidebarMenuItem>
      </SidebarMenu>
    </SidebarGroup>
  </SidebarContent>
</Sidebar>`,
  },
  {
    slug: "skeleton",
    title: "Skeleton",
    blurb: "The shape of content that has not arrived.",
    status: "built",
    odinFile: "shadcn/skeleton.odin",
    odin: `sc.skeleton(ui, "h-4 w-64")
sc.skeleton(ui, "size-10 rounded-full")`,
    react: `<Skeleton className="h-4 w-64" />
<Skeleton className="size-10 rounded-full" />`,
  },
  {
    slug: "slider",
    title: "Slider",
    blurb: "One or two thumbs along a track.",
    status: "built",
    odinFile: "shadcn/slider.odin",
    odin: `// the shadcn-styled track, drawn from values you hold
sc.slider(ui, []f32{0.5}, vertical = false)

// palmy's own widget, which owns the drag
p.slider(ui, &volume, 0, 100)`,
    react: `<Slider defaultValue={[50]} max={100} step={1} />`,
  },
  {
    slug: "spinner",
    title: "Spinner",
    blurb: "An indeterminate wait.",
    status: "built",
    odinFile: "shadcn/spinner.odin",
    odin: `// turns advances the arc; app_elapsed is the clock
sc.spinner(ui, "size-4", p.app_elapsed(app))`,
    react: `<Spinner />`,
  },
  {
    slug: "switch",
    title: "Switch",
    blurb: "On or off, with the thumb travelling.",
    status: "built",
    odinFile: "shadcn/switch.odin",
    odin: `// switch_ has the trailing underscore because switch is an Odin keyword
idx := p.div(ui, "")
sc.switch_(ui, on^, .Default, sc.State{
	focus    = p.focused(ui, idx),
	disabled = !enabled,
})
if p.activated(ui, idx) { on^ = !on^ }

// palmy's own
p.toggle(ui, &enabled)`,
    react: `<Switch checked={on} onCheckedChange={setOn} />`,
  },
  {
    slug: "table",
    title: "Table",
    blurb: "Rows and columns, with a caption and rules.",
    status: "built",
    odinFile: "shadcn/table.odin",
    odin: `sc.table_open(ui)
defer sc.table_end(ui)

sc.table_row_open(ui, 40)
sc.table_head(ui, "Invoice", "w-32")
sc.table_head(ui, "Status", "flex-1")
sc.table_row_end(ui)
sc.table_rule(ui)

for inv in invoices {
	p.key(ui, inv.id)
	sc.table_row_open(ui, 48)
	sc.table_data(ui, inv.id, "w-32")
	sc.table_data(ui, inv.status, "flex-1")
	sc.table_row_end(ui)
}`,
    react: `<Table>
  <TableHeader>
    <TableRow><TableHead>Invoice</TableHead></TableRow>
  </TableHeader>
  <TableBody>
    <TableRow><TableCell>INV001</TableCell></TableRow>
  </TableBody>
</Table>`,
  },
  {
    slug: "tabs",
    title: "Tabs",
    blurb: "A list of triggers over one panel at a time.",
    status: "built",
    odinFile: "shadcn/tabs.odin",
    odin: `tab := p.state(ui, "tab", 0)

sc.tabs_open(ui)
defer sc.tabs_close(ui)

sc.tabs_list_open(ui, .Default)
for label, i in labels {
	p.key(ui, label)
	if sc.tabs_trigger(ui, label, tab^ == i, .Default) { tab^ = i }
}
sc.tabs_list_close(ui)

sc.tabs_content(ui, bodies[tab^])`,
    react: `<Tabs defaultValue="account">
  <TabsList>
    <TabsTrigger value="account">Account</TabsTrigger>
  </TabsList>
  <TabsContent value="account">…</TabsContent>
</Tabs>`,
  },
  {
    slug: "textarea",
    title: "Textarea",
    blurb: "A multi-line text box.",
    status: "built",
    odinFile: "shadcn/textarea.odin",
    odin: `sc.textarea(ui, string(buf[:]), "Type your message here.", sc.State{
	focus = p.focused(ui),
})`,
    react: `<Textarea placeholder="Type your message here." />`,
  },
  {
    slug: "toast",
    title: "Toast",
    blurb: "A transient notification with a title, a body and an action.",
    status: "built",
    odinFile: "shadcn/toast.odin",
    odin: `sc.toast_open(ui)
defer p.end(ui)

sc.toast_content_open(ui)
sc.toast_text_open(ui)
sc.toast_title(ui, "Saved")
sc.toast_description(ui, "Your changes are on disk.")
p.end(ui)
sc.toast_action(ui, "Undo")
sc.toast_close(ui)
p.end(ui)`,
    react: `toast("Saved", {
  description: "Your changes are on disk.",
  action: { label: "Undo", onClick: undo },
})`,
  },
  {
    slug: "toggle",
    title: "Toggle",
    blurb: "A button that stays pressed.",
    status: "built",
    odinFile: "shadcn/toggle.odin",
    sharedWith: ["toggle-group"],
    odin: `if sc.toggle(ui, "B", pressed^, .Outline, .Default, {}) {
	pressed^ = !pressed^
}

// or open/end, when the content is an icon
idx := sc.toggle_open(ui, pressed^, .Default, .Default, {})
p.icon(ui, sc.ICON_BOLD, "size-4")
sc.toggle_end(ui)`,
    react: `<Toggle variant="outline" pressed={pressed} onPressedChange={setPressed}>
  <Bold />
</Toggle>`,
  },
  {
    slug: "toggle-group",
    title: "Toggle Group",
    blurb: "Toggles joined into one control, single or multiple selection.",
    status: "built",
    odinFile: "shadcn/toggle.odin",
    sharedWith: ["toggle"],
    odin: `sc.toggle_group_open(ui)
defer sc.toggle_group_end(ui)

for item, i in items {
	p.key(ui, item)
	if sc.toggle(ui, item, chosen^ == i, .Outline, .Default, {}) { chosen^ = i }
}`,
    react: `<ToggleGroup type="single">
  <ToggleGroupItem value="left"><AlignLeft /></ToggleGroupItem>
  <ToggleGroupItem value="center"><AlignCenter /></ToggleGroupItem>
</ToggleGroup>`,
  },
  {
    slug: "tooltip",
    title: "Tooltip",
    blurb: "A one-line label that appears on hover or focus.",
    status: "partial",
    odinFile: "shadcn/popover.odin",
    sharedWith: ["popover", "hover-card"],
    gap: {
      kind: "overlay",
      detail:
        "The panel and its keyboard-hint slot are built. There is no popup surface, so a tooltip cannot overhang the window, and the dwell delay is the application's.",
    },
    odin: `b := sc.button_open(ui, .Outline, .Default, {})
p.text(ui, "Hover")
sc.button_end(ui)

if p.is_hovered(ui, b) {
	p.div(ui, "absolute z-50")
	sc.tooltip_content_open(ui)
	p.text(ui, "Add to library", "text-xs")
	sc.tooltip_kbd(ui, "⌘L")
	p.end(ui)
	p.end(ui)
}`,
    react: `<Tooltip>
  <TooltipTrigger asChild><Button variant="outline">Hover</Button></TooltipTrigger>
  <TooltipContent>Add to library</TooltipContent>
</Tooltip>`,
  },
];

/* -------------------------------------------------------------------------- */
/* Derived                                                                     */
/* -------------------------------------------------------------------------- */

export const COMPONENT_COUNT = COMPONENTS.length;

export const PARITY_SUMMARY = parity.summary;

export function componentBySlug(slug: string): ComponentEntry | undefined {
  return COMPONENTS.find((c) => c.slug === slug);
}

const SLUGS_BY_LENGTH = [...COMPONENTS]
  .map((c) => c.slug)
  .sort((a, b) => b.length - a.length);

/** Longest slug wins, so `input-otp-default` does not land on `input`. */
function ownerOf(caseId: string): string | null {
  for (const slug of SLUGS_BY_LENGTH) {
    if (caseId === slug || caseId.startsWith(slug + "-")) return slug;
  }
  return null;
}

export type ParityCase = {
  id: string;
  size: string;
  mae: number;
  within2: number;
};

const CASES_BY_SLUG: Record<string, ParityCase[]> = {};
for (const c of parity.cases as ParityCase[]) {
  const owner = ownerOf(c.id);
  if (!owner) continue;
  (CASES_BY_SLUG[owner] ??= []).push(c);
}
for (const list of Object.values(CASES_BY_SLUG)) {
  list.sort((a, b) => a.id.localeCompare(b.id));
}

export function parityCasesFor(slug: string): ParityCase[] {
  return CASES_BY_SLUG[slug] ?? [];
}

export const STATUS_COUNTS = {
  built: COMPONENTS.filter((c) => c.status === "built").length,
  partial: COMPONENTS.filter((c) => c.status === "partial").length,
  absent: COMPONENTS.filter((c) => c.status === "absent").length,
};
