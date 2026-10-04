/* icu-oracle — a second independent UAX #9 reference, for palmy's bidi tests.
 *
 * tools/bidi/fribidi-oracle.c is the first. Two oracles rather than one
 * because they disagree: fribidi 1.0.16's rule N0 scans backwards for the
 * preceding strong context past the end of the isolating run sequence, where
 * the rule says to stop at sos, so it brackets `[hebrew]` the wrong way inside
 * an LRE embedding. ICU is the implementation Unicode's own BidiTest and
 * BidiCharacterTest files are run against, and it agrees with the rule as
 * written, so where the two differ the generator records it and the tests
 * follow ICU.
 *
 * Neither library is ever linked into palmy, which links libc and libm.
 *
 *   build: cc -O2 -o icu-oracle icu-oracle.c $(pkg-config --cflags --libs icu-uc)
 *   in:    one case per line — "<L|R|A> <hex cp> <hex cp> ..."
 *   out:   "<par level>|<level> ...|<logical index in visual order> ..."
 *
 * ICU works in UTF-16 and reports levels per code unit; this prints one level
 * and one visual position per *codepoint*, so that a supplementary character
 * such as U+1E900 ADLAM is one entry, as it is everywhere in palmy.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unicode/ubidi.h>

#define MAXN 4096

int main(void) {
	static char line[MAXN * 8];
	static UChar u[MAXN * 2];
	static int32_t cp_of_unit[MAXN * 2]; /* UTF-16 index -> codepoint index, -1 for a trail surrogate */
	static int32_t unit_of_cp[MAXN];
	static int32_t vmap[MAXN * 2];

	while (fgets(line, sizeof line, stdin)) {
		char *save = NULL;
		char *tok = strtok_r(line, " \t\r\n", &save);
		if (!tok) continue;
		UBiDiLevel para;
		switch (tok[0]) {
		case 'L': para = 0; break;
		case 'R': para = 1; break;
		default:  para = UBIDI_DEFAULT_LTR; break; /* P2/P3 */
		}

		int32_t n = 0;    /* UTF-16 code units */
		int32_t ncp = 0;  /* codepoints */
		while ((tok = strtok_r(NULL, " \t\r\n", &save)) && ncp < MAXN) {
			unsigned long cp = strtoul(tok, NULL, 16);
			unit_of_cp[ncp] = n;
			cp_of_unit[n] = ncp;
			if (cp > 0xFFFF) {
				u[n++] = (UChar)(0xD800 + ((cp - 0x10000) >> 10));
				cp_of_unit[n] = -1;
				u[n++] = (UChar)(0xDC00 + ((cp - 0x10000) & 0x3FF));
			} else {
				u[n++] = (UChar)cp;
			}
			ncp++;
		}

		UErrorCode err = U_ZERO_ERROR;
		UBiDi *bidi = ubidi_open();
		ubidi_setPara(bidi, u, n, para, NULL, &err);
		if (U_FAILURE(err)) {
			fprintf(stderr, "ICU failed: %s\n", u_errorName(err));
			return 1;
		}

		printf("%d|", ubidi_getParaLevel(bidi));
		if (n > 0) {
			const UBiDiLevel *levels = ubidi_getLevels(bidi, &err);
			if (U_FAILURE(err)) {
				fprintf(stderr, "ICU failed: %s\n", u_errorName(err));
				return 1;
			}
			for (int32_t i = 0; i < ncp; i++) {
				printf("%s%d", i ? " " : "", levels[unit_of_cp[i]]);
			}
			printf("|");
			ubidi_getVisualMap(bidi, vmap, &err);
			if (U_FAILURE(err)) {
				fprintf(stderr, "ICU failed: %s\n", u_errorName(err));
				return 1;
			}
			/* vmap[visual] = logical, in code units. Keeping only the lead
			 * unit of each codepoint gives the codepoint order: ICU puts the
			 * trail surrogate first inside an RTL run, which moves nothing
			 * relative to the other codepoints. */
			int first = 1;
			for (int32_t i = 0; i < n; i++) {
				int32_t cp = cp_of_unit[vmap[i]];
				if (cp < 0) continue;
				printf("%s%d", first ? "" : " ", cp);
				first = 0;
			}
		} else {
			printf("|");
		}
		printf("\n");
		ubidi_close(bidi);
	}
	return 0;
}
