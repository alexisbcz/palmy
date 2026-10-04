/* fribidi-oracle — an independent UAX #9 reference, for palmy's bidi tests only.
 *
 * libfribidi is a mature implementation of the Unicode Bidirectional
 * Algorithm. palmy itself links nothing but libc and libm, so fribidi may
 * never appear in a palmy build; this program exists so the *tests* can be
 * written against an implementation that was not written by the same hand as
 * palmy/bidi.odin. It reads a corpus on stdin and prints what fribidi
 * resolves, and tools/bidi/gen-bidi-cases.py turns that into Odin constants.
 *
 *   build: cc -O2 -o fribidi-oracle fribidi-oracle.c $(pkg-config --cflags --libs fribidi)
 *   in:    one case per line — "<L|R|A> <hex cp> <hex cp> ..."
 *   out:   "<par level>|<level> <level> ...|<logical index in visual order> ..."
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fribidi.h>

#define MAXN 4096

/* --props: dump every codepoint's class, mirror and bracket, so the
 * generator can diff palmy's tables against fribidi's copy of the same
 * Unicode data. */
static int dump_props(void) {
	for (FriBidiChar cp = 0; cp <= 0x10FFFF; cp++) {
		FriBidiCharType t = fribidi_get_bidi_type(cp);
		FriBidiChar mirror = cp;
		fribidi_get_mirror_char(cp, &mirror);
		FriBidiBracketType bt = fribidi_get_bracket(cp);
		unsigned paired = 0;
		char kind = 'n';
		if (bt != FRIBIDI_NO_BRACKET) {
			kind = FRIBIDI_IS_BRACKET_OPEN(bt) ? 'O' : 'C';
			paired = (unsigned)FRIBIDI_BRACKET_ID(bt);
		}
		printf("%04X %s %04X %c %04X\n", cp, fribidi_get_bidi_type_name(t),
		       (unsigned)mirror, kind, paired);
	}
	return 0;
}

int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "--props") == 0) return dump_props();
	static char line[MAXN * 8];
	static FriBidiChar str[MAXN];
	static FriBidiCharType types[MAXN];
	static FriBidiBracketType brackets[MAXN];
	static FriBidiLevel levels[MAXN];
	static FriBidiStrIndex map[MAXN];

	while (fgets(line, sizeof line, stdin)) {
		char *save = NULL;
		char *tok = strtok_r(line, " \t\r\n", &save);
		if (!tok) continue;
		FriBidiParType base;
		switch (tok[0]) {
		case 'L': base = FRIBIDI_PAR_LTR; break;
		case 'R': base = FRIBIDI_PAR_RTL; break;
		default:  base = FRIBIDI_PAR_ON;  break; /* P2/P3: first strong wins */
		}
		FriBidiStrIndex n = 0;
		while ((tok = strtok_r(NULL, " \t\r\n", &save)) && n < MAXN) {
			str[n++] = (FriBidiChar)strtoul(tok, NULL, 16);
		}

		fribidi_get_bidi_types(str, n, types);
		fribidi_get_bracket_types(str, n, types, brackets);
		FriBidiParType resolved = base;
		if (n > 0) {
			if (!fribidi_get_par_embedding_levels_ex(types, brackets, n, &resolved, levels)) {
				fprintf(stderr, "fribidi failed on a %d-character case\n", (int)n);
				return 1;
			}
		}
		for (FriBidiStrIndex i = 0; i < n; i++) map[i] = i;
		/* flags 0: plain L1 + L2, with no NSM reordering and no mirroring,
		 * which is what UAX #9 by itself specifies. */
		if (n > 0) { FriBidiLevel m = fribidi_reorder_line(0, types, n, 0, resolved, levels, NULL, map); (void)m; }

		printf("%d|", FRIBIDI_DIR_TO_LEVEL(resolved));
		for (FriBidiStrIndex i = 0; i < n; i++) printf("%s%d", i ? " " : "", levels[i]);
		printf("|");
		for (FriBidiStrIndex i = 0; i < n; i++) printf("%s%d", i ? " " : "", (int)map[i]);
		printf("\n");
	}
	return 0;
}
