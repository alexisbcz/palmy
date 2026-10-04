package main

// A few lucide paths the shadcn icon set does not carry, in the same form its
// generator emits: one path string, a 24 unit view box, stroked.

import p "palmy:."

IC_TYPE :: p.Icon {
	name   = "type",
	d      = "M4 7 L4 4 L20 4 L20 7 M9 20 L15 20 M12 4 L12 20",
	view   = 24,
	stroke = 2,
}

IC_SQUARE :: p.Icon {
	name   = "square",
	d      = "M5 3 L19 3 C20.1 3 21 3.9 21 5 L21 19 C21 20.1 20.1 21 19 21 L5 21 C3.9 21 3 20.1 3 19 L3 5 C3 3.9 3.9 3 5 3 Z",
	view   = 24,
	stroke = 2,
}

IC_CIRCLE :: p.Icon {
	name   = "circle",
	d      = "M2 12 C2 6.477152501692064 6.477152501692064 2 12 2 C17.522847498307936 2 22 6.477152501692064 22 12 C22 17.522847498307936 17.522847498307936 22 12 22 C6.477152501692064 22 2 17.522847498307936 2 12 Z",
	view   = 24,
	stroke = 2,
}

IC_SLASH :: p.Icon {
	name   = "slash",
	d      = "M22 2 L2 22",
	view   = 24,
	stroke = 2,
}

IC_KEYBOARD :: p.Icon {
	name   = "keyboard",
	d      = "M10 8 L10.01 8 M12 12 L12.01 12 M14 8 L14.01 8 M16 12 L16.01 12 M18 8 L18.01 8 M6 8 L6.01 8 M7 16 L17 16 M8 12 L8.01 12 M4 4 L20 4 C21.104569499661586 4 22 4.895430500338413 22 6 L22 18 C22 19.104569499661586 21.104569499661586 20 20 20 L4 20 C2.8954305003384126 20 2 19.104569499661586 2 18 L2 6 C2 4.895430500338413 2.8954305003384126 4 4 4 Z",
	view   = 24,
	stroke = 2,
}

IC_PLAY :: p.Icon {
	name   = "play",
	d      = "M6 4 L20 12 L6 20 Z",
	view   = 24,
	stroke = 2,
}

IC_PRESENTATION :: p.Icon {
	name   = "presentation",
	d      = "M2 3 L22 3 M21 3 L21 14 C21 15.1 20.1 16 19 16 L5 16 C3.9 16 3 15.1 3 14 L3 3 M7 21 L12 16 L17 21",
	view   = 24,
	stroke = 2,
}
