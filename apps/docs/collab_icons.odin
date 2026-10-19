package main

// Icons for the collaboration chrome, after lucide's message-square,
// pencil-line, history, users and bookmark, written with the M/L/C/Z subset
// palmy's path parser reads.

import p "palmy:."

ICON_MESSAGE_SQUARE :: p.Icon{name = "message-square", d = "M21 15 C21 16.105 20.105 17 19 17 L7 17 L3 21 L3 5 C3 3.895 3.895 3 5 3 L19 3 C20.105 3 21 3.895 21 5 Z", view = 24, stroke = 2}
ICON_PENCIL_LINE :: p.Icon{name = "pencil-line", d = "M12 20 L21 20 M16.5 3.5 C17.328 2.672 18.672 2.672 19.5 3.5 C20.328 4.328 20.328 5.672 19.5 6.5 L7 19 L3 20 L4 16 Z M15 5 L18 8", view = 24, stroke = 2}
ICON_HISTORY :: p.Icon{name = "history", d = "M3 12 C3 16.971 7.029 21 12 21 C16.971 21 21 16.971 21 12 C21 7.029 16.971 3 12 3 C9.484 3.009 7.069 3.991 5.26 5.74 L3 8 M3 3 L3 8 L8 8 M12 7 L12 12 L16 14", view = 24, stroke = 2}
ICON_USERS :: p.Icon{name = "users", d = "M16 21 L16 19 C16 16.791 14.209 15 12 15 L6 15 C3.791 15 2 16.791 2 19 L2 21 M5 7 C5 4.791 6.791 3 9 3 C11.209 3 13 4.791 13 7 C13 9.209 11.209 11 9 11 C6.791 11 5 9.209 5 7 Z M22 21 L22 19 C21.999 17.177 20.765 15.586 19 15.13 M16 3.13 C17.77 3.583 19.008 5.178 19.008 7.005 C19.008 8.832 17.77 10.427 16 10.88", view = 24, stroke = 2}
ICON_BOOKMARK :: p.Icon{name = "bookmark", d = "M19 21 L12 17 L5 21 L5 5 C5 3.895 5.895 3 7 3 L17 3 C18.105 3 19 3.895 19 5 Z", view = 24, stroke = 2}
