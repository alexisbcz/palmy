package main

// A few icons this app needs that the shared set does not carry, in lucide's
// geometry and on lucide's 24-unit view box. They live here rather than in
// `shadcn/icons.odin` because that file is shared and this app does not own it.

import p "palmy:."

// Two filled bars.
ICON_PAUSE :: p.Icon {
	name   = "pause",
	d      = "M14 4 L18 4 L18 20 L14 20 Z M6 4 L10 4 L10 20 L6 20 Z",
	view   = 24,
	stroke = 0,
	fill   = true,
}

// A filled triangle.
ICON_PLAY :: p.Icon {
	name   = "play",
	d      = "M6 3 L20 12 L6 21 Z",
	view   = 24,
	stroke = 0,
	fill   = true,
}

ICON_ARROW_UP :: p.Icon {
	name   = "arrow-up",
	d      = "M12 19 L12 5 M5 12 L12 5 L19 12",
	view   = 24,
	stroke = 2,
}

// lucide's `rotate-cw`, with the arc written as two cubics rather than an `A`
// command, which palmy's path parser does not implement.
ICON_RECHECK :: p.Icon {
	name   = "recheck",
	d      = "M21 12 C21 16.971 16.971 21 12 21 C7.029 21 3 16.971 3 12 C3 7.029 7.029 3 12 3 C15.1 3 17.833 4.568 19.45 6.96 M21 3 L21 8 L16 8",
	view   = 24,
	stroke = 2,
}

ICON_MAGNET :: p.Icon {
	name   = "magnet",
	d      = "M6 15 L6 6 C6 3.791 7.791 2 10 2 C12.209 2 14 3.791 14 6 L14 15 M10 15 L10 6 M2 15 L10 15 M14 15 L22 15 M18 15 L18 6 C18 3.791 16.209 2 14 2 M2 15 L2 18 C2 20.209 3.791 22 6 22 C8.209 22 10 20.209 10 18 L10 15 M14 15 L14 18 C14 20.209 15.791 22 18 22 C20.209 22 22 20.209 22 18 L22 15",
	view   = 24,
	stroke = 2,
}
