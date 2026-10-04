// Categorisation: reading a French bank label.
//
// French retail bank labels are terse, upper-case and full of the bank's own
// bookkeeping:
//
//     CB CARREFOUR 2109                 card purchase, the 21st of September
//     PRLV SEPA EDF ECH 210926 MDT 5512 direct debit, with mandate reference
//     VIR M DUPONT LOYER OCTOBRE        a transfer in, with a free-text note
//     RETRAIT DAB 18/09 BNP PARIS 14E   cash out of a machine
//
// Three things have to be pulled out of that:
//
//   * the **method** — the first word. `CB`, `PRLV`, `VIR`, `CHQ`, `RETRAIT`
//     are not decoration: a `PRLV` repeating monthly is a subscription, a
//     `RETRAIT` can never be categorised from its label because the label
//     cannot know what the cash bought, and a `VIR` may be a transfer between
//     the user's own accounts rather than spending at all.
//   * the **merchant key** — the label with the method, the dates, the card
//     suffixes and the bank's reference numbers stripped out, so that `CB
//     CARREFOUR 2109` and `CB CARREFOUR 1410` are recognised as the same
//     shop. Everything downstream (learning, recurrence detection) keys off
//     this.
//   * the **category**, by matching patterns against the normalised label.
//
// The rules the application ships with are a starting point; the ones that
// matter are learned. When the user categorises something by hand, the
// merchant key becomes a learned rule, and a learned rule outranks every
// built-in one — the user is always right about their own statement.
package main

import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Normalising a label
// ---------------------------------------------------------------------------

// label_normalize upper-cases, folds the accented letters a French bank may
// or may not have stripped already, and collapses runs of whitespace and
// punctuation to single spaces. Two labels that differ only in those respects
// have to compare equal or every rule below is unreliable.
label_normalize :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	space := true // leading space suppressed
	for r in s {
		c := r
		switch c {
		case 'à', 'â', 'ä', 'á', 'À', 'Â', 'Ä', 'Á':
			c = 'A'
		case 'é', 'è', 'ê', 'ë', 'É', 'È', 'Ê', 'Ë':
			c = 'E'
		case 'î', 'ï', 'í', 'Î', 'Ï', 'Í':
			c = 'I'
		case 'ô', 'ö', 'ó', 'Ô', 'Ö', 'Ó':
			c = 'O'
		case 'ù', 'û', 'ü', 'ú', 'Ù', 'Û', 'Ü', 'Ú':
			c = 'U'
		case 'ç', 'Ç':
			c = 'C'
		case 'ÿ', 'Ý':
			c = 'Y'
		case 'ñ', 'Ñ':
			c = 'N'
		}
		switch {
		case c >= 'a' && c <= 'z':
			strings.write_rune(&b, c - 32)
			space = false
		case (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			strings.write_rune(&b, c)
			space = false
		case c == '\'' || c == '&' || c == '.' || c == '-' || c == '/' || c == '*':
			// Kept as a separator rather than as a character: `UBER*EATS`
			// and `UBER EATS` are one merchant.
			if !space {
				strings.write_byte(&b, ' ')
				space = true
			}
		case:
			if !space {
				strings.write_byte(&b, ' ')
				space = true
			}
		}
	}
	out := strings.to_string(b)
	return strings.trim_space(out)
}

// METHOD_WORDS maps the opening word of a label to a payment method. Order
// matters: the longer phrases are tested first so `PAIEMENT CB` does not
// match on `PAIEMENT` alone.
METHOD_WORDS := [?]struct {
	word: string,
	m:    Method,
} {
	{"PAIEMENT PAR CARTE", .Card},
	{"PAIEMENT CARTE", .Card},
	{"PAIEMENT CB", .Card},
	{"ACHAT CB", .Card},
	{"CARTE BANCAIRE", .Card},
	{"FACTURE CARTE", .Card},
	{"CB", .Card},
	{"CARTE", .Card},
	{"PRLV SEPA", .Debit},
	{"PRELEVEMENT SEPA", .Debit},
	{"PRELEVEMENT", .Debit},
	{"PRLV", .Debit},
	{"VIR SEPA RECU", .Transfer},
	{"VIR SEPA", .Transfer},
	{"VIREMENT RECU", .Transfer},
	{"VIREMENT", .Transfer},
	{"VIR INST", .Transfer},
	{"VIR", .Transfer},
	{"CHEQUE", .Cheque},
	{"CHQ", .Cheque},
	{"RETRAIT DAB", .Cash},
	{"RETRAIT", .Cash},
	{"RET DAB", .Cash},
	{"COTISATION", .Fee},
	{"FRAIS", .Fee},
	{"COMMISSION", .Fee},
	{"AGIOS", .Fee},
	{"REMISE CHEQUE", .Deposit},
	{"REMISE", .Deposit},
	{"VERSEMENT", .Deposit},
}

// label_method reads the method off the front of a normalised label and
// returns the rest of it.
label_method :: proc(normalized: string) -> (m: Method, rest: string) {
	for e in METHOD_WORDS {
		if normalized == e.word {
			return e.m, ""
		}
		if strings.has_prefix(normalized, e.word) && len(normalized) > len(e.word) {
			if normalized[len(e.word)] == ' ' {
				return e.m, strings.trim_space(normalized[len(e.word) + 1:])
			}
		}
	}
	return .Unknown, normalized
}

// NOISE are the words a bank sprinkles through a label that say nothing about
// who was paid: references, mandates, due dates, card suffixes.
NOISE := [?]string {
	"SEPA",
	"ECH",
	"MDT",
	"MANDAT",
	"REF",
	"RUM",
	"ID",
	"FACT",
	"FACTURE",
	"DU",
	"LE",
	"NUM",
	"NO",
	"CARTE",
	"NUMERO",
	"DE",
	"PAR",
	"AVEC",
	"EUR",
	"TPE",
	"CONTRAT",
	"ABONNEMENT",
	"CLIENT",
	"COMPTE",
	"DAB",
	"PAIEMENT",
	"ACHAT",
}

@(private = "file")
is_noise :: proc(tok: string) -> bool {
	for n in NOISE {
		if tok == n {
			return true
		}
	}
	return false
}

@(private = "file")
all_digits :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

@(private = "file")
mostly_digits :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	d := 0
	for i in 0 ..< len(s) {
		if s[i] >= '0' && s[i] <= '9' {
			d += 1
		}
	}
	return d * 2 >= len(s)
}

// MERCHANT_KEY_WORDS is how many words of the cleaned label make the key.
// Two is the figure that works: one word collapses `SUPER U` and `SUPER
// MARCHE`, and four splits a merchant whose label carries a shop number as a
// word.
MERCHANT_KEY_WORDS :: 2

// merchant_key is the stable identity of whoever was paid.
//
// `CB CARREFOUR 2109` and `CB CARREFOUR MARKET 1410` both key to CARREFOUR;
// `PRLV SEPA EDF ECH 210926 MDT 5512` keys to EDF. The date and reference
// numbers have to go, or every month's charge from the same company looks
// like a different merchant and nothing recurring is ever found.
merchant_key :: proc(label: string, allocator := context.temp_allocator) -> string {
	norm := label_normalize(label, context.temp_allocator)
	_, rest := label_method(norm)
	if rest == "" {
		rest = norm
	}
	toks := strings.split(rest, " ", context.temp_allocator)
	keep := make([dynamic]string, 0, len(toks), context.temp_allocator)
	for t in toks {
		if t == "" || is_noise(t) {
			continue
		}
		// A pure number, or a token that is mostly digits, is the bank's
		// reference and not a name. Short all-letter tokens are kept: `RATP`
		// and `EDF` are names.
		if all_digits(t) || mostly_digits(t) {
			continue
		}
		if len(t) == 1 {
			continue
		}
		append(&keep, t)
		if len(keep) >= MERCHANT_KEY_WORDS {
			break
		}
	}
	if len(keep) == 0 {
		// Nothing but references: key on the method so a cash withdrawal at
		// least groups with other cash withdrawals.
		return strings.clone(norm, allocator)
	}
	return strings.join(keep[:], " ", allocator)
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

Rule_Source :: enum {
	Builtin, // shipped with the application
	Learned, // derived from something the user categorised by hand
	User, // typed in by the user
}

Rule :: struct {
	pattern:  string, // a normalised substring; matched against the whole label
	category: string, // by name, so a rule survives the accounts being renumbered
	method:   Method, // .Unknown matches any method
	income:   bool, // match only credits, for SALAIRE and the like
	source:   Rule_Source,
	hits:     int,
}

Catalog :: struct {
	rules: [dynamic]Rule,
}

// BUILTIN is the shipped rule set: the merchants, utilities and
// administrations a French account sees, and the bank's own charges. It is
// deliberately a list of plain substrings — a regular-expression engine would
// be a worse fit for labels that are already this crude, and a substring rule
// is one the user can read and correct.
BUILTIN := [?]Rule {
	// Alimentation
	{"CARREFOUR", "Alimentation", .Unknown, false, .Builtin, 0},
	{"LECLERC", "Alimentation", .Unknown, false, .Builtin, 0},
	{"INTERMARCHE", "Alimentation", .Unknown, false, .Builtin, 0},
	{"SUPER U", "Alimentation", .Unknown, false, .Builtin, 0},
	{"LIDL", "Alimentation", .Unknown, false, .Builtin, 0},
	{"AUCHAN", "Alimentation", .Unknown, false, .Builtin, 0},
	{"MONOPRIX", "Alimentation", .Unknown, false, .Builtin, 0},
	{"FRANPRIX", "Alimentation", .Unknown, false, .Builtin, 0},
	{"PICARD", "Alimentation", .Unknown, false, .Builtin, 0},
	{"BIOCOOP", "Alimentation", .Unknown, false, .Builtin, 0},
	{"NATURALIA", "Alimentation", .Unknown, false, .Builtin, 0},
	{"BOULANGERIE", "Alimentation", .Unknown, false, .Builtin, 0},
	{"MARCHE", "Alimentation", .Unknown, false, .Builtin, 0},
	// Restaurants
	{"RESTAURANT", "Restaurants", .Unknown, false, .Builtin, 0},
	{"BRASSERIE", "Restaurants", .Unknown, false, .Builtin, 0},
	{"MCDONALD", "Restaurants", .Unknown, false, .Builtin, 0},
	{"BURGER", "Restaurants", .Unknown, false, .Builtin, 0},
	{"PIZZ", "Restaurants", .Unknown, false, .Builtin, 0},
	{"SUSHI", "Restaurants", .Unknown, false, .Builtin, 0},
	{"UBER EATS", "Restaurants", .Unknown, false, .Builtin, 0},
	{"DELIVEROO", "Restaurants", .Unknown, false, .Builtin, 0},
	{"CAFE", "Restaurants", .Unknown, false, .Builtin, 0},
	// Transports
	{"SNCF", "Transports", .Unknown, false, .Builtin, 0},
	{"RATP", "Transports", .Unknown, false, .Builtin, 0},
	{"NAVIGO", "Transports", .Unknown, false, .Builtin, 0},
	{"UBER", "Transports", .Unknown, false, .Builtin, 0},
	{"BLABLACAR", "Transports", .Unknown, false, .Builtin, 0},
	{"VELIB", "Transports", .Unknown, false, .Builtin, 0},
	{"TOTAL ACCESS", "Transports", .Unknown, false, .Builtin, 0},
	{"ESSO", "Transports", .Unknown, false, .Builtin, 0},
	{"AUTOROUTE", "Transports", .Unknown, false, .Builtin, 0},
	{"VINCI AUTOROUTES", "Transports", .Unknown, false, .Builtin, 0},
	{"PARKING", "Transports", .Unknown, false, .Builtin, 0},
	// Logement et énergie
	{"LOYER", "Logement", .Unknown, false, .Builtin, 0},
	{"FONCIA", "Logement", .Unknown, false, .Builtin, 0},
	{"SYNDIC", "Logement", .Unknown, false, .Builtin, 0},
	{"EDF", "Énergie", .Unknown, false, .Builtin, 0},
	{"ENGIE", "Énergie", .Unknown, false, .Builtin, 0},
	{"TOTALENERGIES", "Énergie", .Unknown, false, .Builtin, 0},
	{"VEOLIA", "Énergie", .Unknown, false, .Builtin, 0},
	{"SUEZ", "Énergie", .Unknown, false, .Builtin, 0},
	{"SAUR", "Énergie", .Unknown, false, .Builtin, 0},
	// Télécom et abonnements
	{"FREE MOBILE", "Télécom", .Unknown, false, .Builtin, 0},
	{"FREE HAUT DEBIT", "Télécom", .Unknown, false, .Builtin, 0},
	{"ORANGE", "Télécom", .Unknown, false, .Builtin, 0},
	{"SFR", "Télécom", .Unknown, false, .Builtin, 0},
	{"BOUYGUES", "Télécom", .Unknown, false, .Builtin, 0},
	{"SOSH", "Télécom", .Unknown, false, .Builtin, 0},
	{"NETFLIX", "Abonnements", .Unknown, false, .Builtin, 0},
	{"SPOTIFY", "Abonnements", .Unknown, false, .Builtin, 0},
	{"DEEZER", "Abonnements", .Unknown, false, .Builtin, 0},
	{"CANAL", "Abonnements", .Unknown, false, .Builtin, 0},
	{"DISNEY", "Abonnements", .Unknown, false, .Builtin, 0},
	{"ICLOUD", "Abonnements", .Unknown, false, .Builtin, 0},
	{"OVH", "Abonnements", .Unknown, false, .Builtin, 0},
	// Santé
	{"PHARMACIE", "Santé", .Unknown, false, .Builtin, 0},
	{"LABORATOIRE", "Santé", .Unknown, false, .Builtin, 0},
	{"DENTAIRE", "Santé", .Unknown, false, .Builtin, 0},
	{"DOCTEUR", "Santé", .Unknown, false, .Builtin, 0},
	{"MUTUELLE", "Santé", .Unknown, false, .Builtin, 0},
	{"CPAM", "Santé", .Unknown, false, .Builtin, 0},
	// Assurances
	{"ASSURANCE", "Assurances", .Unknown, false, .Builtin, 0},
	{"MAIF", "Assurances", .Unknown, false, .Builtin, 0},
	{"MACIF", "Assurances", .Unknown, false, .Builtin, 0},
	{"MATMUT", "Assurances", .Unknown, false, .Builtin, 0},
	{"AXA", "Assurances", .Unknown, false, .Builtin, 0},
	// Loisirs et achats
	{"FNAC", "Loisirs", .Unknown, false, .Builtin, 0},
	{"CULTURA", "Loisirs", .Unknown, false, .Builtin, 0},
	{"DECATHLON", "Loisirs", .Unknown, false, .Builtin, 0},
	{"CINEMA", "Loisirs", .Unknown, false, .Builtin, 0},
	{"BASIC FIT", "Loisirs", .Unknown, false, .Builtin, 0},
	{"AMAZON", "Achats", .Unknown, false, .Builtin, 0},
	{"CDISCOUNT", "Achats", .Unknown, false, .Builtin, 0},
	{"IKEA", "Achats", .Unknown, false, .Builtin, 0},
	{"LEROY MERLIN", "Achats", .Unknown, false, .Builtin, 0},
	{"ZARA", "Achats", .Unknown, false, .Builtin, 0},
	{"UNIQLO", "Achats", .Unknown, false, .Builtin, 0},
	{"VINTED", "Achats", .Unknown, false, .Builtin, 0},
	{"ACTION", "Achats", .Unknown, false, .Builtin, 0},
	// Impôts et charges
	{"DGFIP", "Impôts", .Unknown, false, .Builtin, 0},
	{"IMPOT", "Impôts", .Unknown, false, .Builtin, 0},
	{"TRESOR PUBLIC", "Impôts", .Unknown, false, .Builtin, 0},
	{"TAXE", "Impôts", .Unknown, false, .Builtin, 0},
	{"URSSAF", "Impôts", .Unknown, false, .Builtin, 0},
	// Revenus — credits only, so a payment *to* an employer is not income
	{"SALAIRE", "Salaire", .Unknown, true, .Builtin, 0},
	{"PAIE", "Salaire", .Unknown, true, .Builtin, 0},
	{"REMUNERATION", "Salaire", .Unknown, true, .Builtin, 0},
	{"CAF", "Allocations", .Unknown, true, .Builtin, 0},
	{"POLE EMPLOI", "Allocations", .Unknown, true, .Builtin, 0},
	{"REMBOURSEMENT", "Remboursements", .Unknown, true, .Builtin, 0},
	// The bank's own charges, which are a method rather than a merchant
	{"", "Frais bancaires", .Fee, false, .Builtin, 0},
	// Cash. The label cannot say what it bought, so it gets its own category
	// rather than a wrong one.
	{"", "Retraits", .Cash, false, .Builtin, 0},
}

catalog_init :: proc(c: ^Catalog) {
	c.rules = make([dynamic]Rule)
	for r in BUILTIN {
		rr := r
		rr.pattern = strings.clone(r.pattern)
		rr.category = strings.clone(r.category)
		append(&c.rules, rr)
	}
}

catalog_destroy :: proc(c: ^Catalog) {
	for r in c.rules {
		delete(r.pattern)
		delete(r.category)
	}
	delete(c.rules)
}

// catalog_categories is every category any rule can produce, in the order
// they first appear, which is how the accounts get created at startup.
catalog_categories :: proc(c: ^Catalog, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for r in c.rules {
		if r.category == "" || seen[r.category] {
			continue
		}
		seen[r.category] = true
		append(&out, r.category)
	}
	return out[:]
}

Match :: struct {
	category: string,
	rule:     int, // index into Catalog.rules, -1 when nothing matched
	score:    int, // how specific the match was; bigger wins
	source:   Rule_Source,
}

// catalog_match picks the best rule for a label.
//
// "Best" is the most specific: a learned rule beats a built-in one, and among
// equals the longer pattern wins, so `UBER EATS` is a restaurant while plain
// `UBER` is transport. A method-only rule (bank charges, cash) is the weakest
// match, so it only applies when nothing named a merchant.
catalog_match :: proc(c: ^Catalog, label: string, method: Method, amount: Cents) -> Match {
	norm := label_normalize(label, context.temp_allocator)
	best := Match {
		rule  = -1,
		score = -1,
	}
	for r, i in c.rules {
		if r.income && amount <= 0 {
			continue
		}
		if r.method != .Unknown && r.method != method {
			continue
		}
		if r.pattern != "" && !strings.contains(norm, r.pattern) {
			continue
		}
		score := len(r.pattern) * 4
		if r.pattern == "" {
			score = 1 // a method-only rule is the last resort
		}
		switch r.source {
		case .Learned:
			score += 10_000
		case .User:
			score += 20_000
		case .Builtin:
		}
		if score > best.score {
			best = Match{r.category, i, score, r.source}
		}
	}
	return best
}

// catalog_learn records what the user decided.
//
// The rule it writes is the merchant key, not the whole label: the whole
// label contains a date and a reference and would never match again. If a
// learned rule for that key already exists it is retargeted — the user
// changing their mind has to change the rule, not add a competing one.
catalog_learn :: proc(c: ^Catalog, label: string, category: string) -> (rule: int, replaced: bool) {
	key := merchant_key(label, context.temp_allocator)
	if key == "" {
		return -1, false
	}
	for &r, i in c.rules {
		if r.source == .Learned && r.pattern == key {
			if r.category != category {
				delete(r.category)
				r.category = strings.clone(category)
				return i, true
			}
			return i, false
		}
	}
	append(
		&c.rules,
		Rule {
			pattern = strings.clone(key),
			category = strings.clone(category),
			method = .Unknown,
			source = .Learned,
		},
	)
	return len(c.rules) - 1, false
}

// catalog_user_rule adds a rule the user typed, which is the strongest kind.
catalog_user_rule :: proc(c: ^Catalog, pattern, category: string, method := Method.Unknown) -> int {
	norm := label_normalize(pattern, context.temp_allocator)
	for &r, i in c.rules {
		if r.source == .User && r.pattern == norm && r.method == method {
			delete(r.category)
			r.category = strings.clone(category)
			return i
		}
	}
	append(
		&c.rules,
		Rule {
			pattern = strings.clone(norm),
			category = strings.clone(category),
			method = method,
			source = .User,
		},
	)
	return len(c.rules) - 1
}

// ---------------------------------------------------------------------------
// Suggesting from history
// ---------------------------------------------------------------------------

Suggestion :: struct {
	category: int, // account index, -1 when there is nothing to suggest
	from:     string, // "règle", "appris", "historique"
	count:    int, // how many past transactions agreed, for the history case
}

// suggest_category answers "what is this, probably".
//
// It asks the rules first, and if they have nothing it asks the user's own
// history: among the transactions already categorised by hand with the same
// merchant key, the most common category. That is the suggestion that gets
// better the more the application is used, and it is the one a rule table
// cannot produce, because it knows about this user's shops.
suggest_category :: proc(l: ^Ledger, c: ^Catalog, label: string, method: Method, amount: Cents) -> Suggestion {
	m := catalog_match(c, label, method, amount)
	if m.rule >= 0 {
		if idx, ok := account_find(l, m.category); ok {
			return {idx, m.source == .Builtin ? "règle" : "appris", 0}
		}
	}

	key := merchant_key(label, context.temp_allocator)
	tally := make(map[int]int, context.temp_allocator)
	for &t in l.txns {
		if t.dead || t.auto_cat {
			continue // only what the user decided counts as evidence
		}
		if merchant_key(t.label, context.temp_allocator) != key {
			continue
		}
		cat := txn_category(l, &t)
		if cat >= 0 {
			tally[cat] += 1
		}
	}
	best := -1
	best_n := 0
	for cat, n in tally {
		if n > best_n || (n == best_n && cat < best) {
			best = cat
			best_n = n
		}
	}
	if best >= 0 {
		return {best, "historique", best_n}
	}
	return {-1, "", 0}
}

// apply_rules categorises every uncategorised transaction it can, and returns
// how many it moved. Nothing the user has touched is overwritten: `auto_cat`
// marks the ones a rule placed, and only those are revisited.
apply_rules :: proc(l: ^Ledger, c: ^Catalog) -> (moved: int) {
	for &t in l.txns {
		if t.dead || txn_is_transfer(l, &t) {
			continue
		}
		cat := txn_category(l, &t)
		if cat >= 0 && !t.auto_cat {
			continue
		}
		amount := txn_amount(l, &t)
		m := catalog_match(c, t.label, t.method, amount)
		if m.rule < 0 {
			continue
		}
		kind: Account_Kind = amount > 0 ? .Income : .Expense
		target := account_get_or_add(l, m.category, kind)
		if target == cat {
			continue
		}
		if txn_categorise(l, t.id, target) {
			t2, _ := txn_get(l, t.id)
			t2.auto_cat = true
			c.rules[m.rule].hits += 1
			moved += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Spend by category, which both the chart and the budget view need
// ---------------------------------------------------------------------------

Cat_Total :: struct {
	account: int,
	total:   Cents,
	count:   int,
}

// spend_by_category sums the expense side over a date range, largest first.
// Transfers are excluded: moving money to a savings account is not spending,
// and a chart that says otherwise is lying about the month.
spend_by_category :: proc(
	l: ^Ledger,
	lo, hi: Date,
	allocator := context.temp_allocator,
) -> []Cat_Total {
	sums := make([]Cents, len(l.accounts), context.temp_allocator)
	counts := make([]int, len(l.accounts), context.temp_allocator)
	for &t in l.txns {
		if t.dead || !date_within(t.date, lo, hi) || txn_is_transfer(l, &t) {
			continue
		}
		for e in t.entries {
			if l.accounts[e.account].kind == .Expense {
				sums[e.account] += e.amount
				counts[e.account] += 1
			}
		}
	}
	out := make([dynamic]Cat_Total, allocator)
	for s, i in sums {
		if s != 0 {
			append(&out, Cat_Total{i, s, counts[i]})
		}
	}
	slice.sort_by(out[:], proc(a, b: Cat_Total) -> bool {
		if a.total != b.total {
			return a.total > b.total
		}
		return a.account < b.account
	})
	return out[:]
}
