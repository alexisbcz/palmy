// The fixtures, and everything is fictitious.
//
// Every name here is invented, every IBAN is built on bank code 99999 — which
// no French bank is assigned — and every amount is a round synthetic figure.
// The IBANs have correct ISO 13616 check digits and correct clé RIB, because
// a fixture that fails validation tests nothing; they identify no account
// anywhere. Nothing in this file, in the demo or in a screenshot resembles
// real personal financial data, and the user's own book is never read to make
// one.
//
// The fixtures are deliberately awkward, because the real files are. Between
// them they cover: a four-line preamble before the header; separate Débit and
// Crédit columns; a single signed column; `1 234,56` and `1.234,56` and
// `-42.10`; `31/01/2026`, `31/01/26` and `2026-01-31`; quoted fields holding
// the delimiter; Windows-1252 and UTF-8; a file with no header at all; OFX
// SGML with unclosed tags; OFX 2 XML; CAMT.053 with a namespace prefix. And
// the malformed cases: a truncated file, an impossible date, an amount with a
// thousands separator read under the wrong assumption, and a repeated
// transaction id.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// Fictitious accounts. Bank code 99999 is not issued to anyone.
FX_IBAN_CURRENT :: "FR7699999000010000001234537"
FX_IBAN_SAVINGS :: "FR7699999000010000006789048"
// The same IBAN with two digits transposed, which must fail the checksum.
FX_IBAN_TRANSPOSED :: "FR7699999000010000001235437"

// ---------------------------------------------------------------------------
// CSV: a French retail bank with a preamble and Débit/Crédit columns
// ---------------------------------------------------------------------------

FX_ALPHA_CSV :: `Relevé de compte - BANQUE ALPHA (exemple)
Compte n° FR7699999000010000001234537 - TITULAIRE EXEMPLE
Période du 01/09/2026 au 30/09/2026
Solde au 01/09/2026;;;;1 000,00

Date;Libellé;Débit;Crédit;Solde
02/09/2026;VIR SALAIRE SOCIETE EXEMPLE SA;;2 450,00;3 450,00
03/09/2026;PRLV SEPA LOYER AGENCE EXEMPLE ECH 030926;950,00;;2 500,00
04/09/2026;CB CARREFOUR 0409;82,40;;2 417,60
05/09/2026;PRLV SEPA EDF ECH 050926 MDT 5512;64,20;;2 353,40
06/09/2026;CB SNCF CONNECT 0609;45,00;;2 308,40
07/09/2026;PRLV SEPA FREE MOBILE 070926;19,99;;2 288,41
08/09/2026;RETRAIT DAB 08/09 PARIS 14E;60,00;;2 228,41
10/09/2026;CB BOULANGERIE DU COIN 1009;7,80;;2 220,61
11/09/2026;PRLV SEPA NETFLIX 110926;13,49;;2 207,12
12/09/2026;CB PHARMACIE CENTRALE 1209;23,15;;2 183,97
14/09/2026;CB CARREFOUR 1409;64,95;;2 119,02
15/09/2026;CHQ 0000123;120,00;;1 999,02
17/09/2026;VIR M EXEMPLE EPARGNE;200,00;;1 799,02
18/09/2026;CB UBER EATS 1809;28,60;;1 770,42
20/09/2026;COTISATION CARTE BANCAIRE;4,50;;1 765,92
21/09/2026;CB CARREFOUR 2109;91,25;;1 674,67
22/09/2026;PRLV SEPA ASSURANCE MAIF ECH 220926;38,00;;1 636,67
24/09/2026;CB DECATHLON 2409;54,90;;1 581,77
26/09/2026;VIR REMBOURSEMENT CPAM;;42,30;1 624,07
28/09/2026;CB FRANPRIX 2809;31,05;;1 593,02
30/09/2026;PRLV SEPA SPOTIFY 300926;11,99;;1 581,03
`

// ---------------------------------------------------------------------------
// CSV: comma-delimited, one signed column, ISO dates, quoted labels
// ---------------------------------------------------------------------------

FX_BETA_CSV :: `Date de l'opération,Description,Montant,Référence
2026-10-01,"CB LE PETIT CAFE, PARIS 1011",-4.80,OP10001
2026-10-01,"VIR SALAIRE SOCIETE EXEMPLE SA",2450.00,OP10002
2026-10-02,"PRLV SEPA LOYER AGENCE EXEMPLE ECH 021026",-950.00,OP10003
2026-10-02,"CB AMAZON, MARKETPLACE 0210",-36.90,OP10004
2026-10-03,"PRLV SEPA EDF ECH 031026 MDT 5512",-64.20,OP10005
2026-10-03,"CB LIDL 0310",-47.35,OP10006
2026-10-04,"PRLV SEPA FREE MOBILE 041026",-19.99,OP10007
2026-10-04,"CB RATP NAVIGO 0410",-88.80,OP10008
`

// ---------------------------------------------------------------------------
// CSV: no header at all, tab-separated, two-digit years, grouped thousands
// ---------------------------------------------------------------------------

FX_GAMMA_CSV :: "05/10/26\tCB IKEA 0510\t-1 249,00\n06/10/26\tVIR PRIME EXEMPLE\t1 200,00\n07/10/26\tCB MONOPRIX 0710\t-23,45\n08/10/26\tPRLV SEPA VEOLIA ECH 081026\t-34,10\n"

// ---------------------------------------------------------------------------
// CSV: the malformed cases, all in one file
//
// Row 2 is an impossible date — 31 February does not exist in any year, and
// an importer that range-checks instead of calendar-checking accepts it.
// Row 3 carries `1.234,56`, which is 1 234,56 € and not 1,23 €. Row 5 is
// truncated: the file was cut mid-record, which is what a half-finished
// download looks like. Row 6 repeats row 4's reference.
// ---------------------------------------------------------------------------

FX_BAD_CSV :: `Date;Libellé;Montant;Référence
01/10/2026;CB CARREFOUR 0110;-42,10;OP20001
31/02/2026;CB JOUR IMPOSSIBLE;-10,00;OP20002
02/10/2026;CB GROS ACHAT 0210;-1.234,56;OP20003
03/10/2026;PRLV SEPA EDF ECH 031026;-64,20;OP20004
04/10/2026;CB COUPE
`

FX_DUP_CSV :: `Date;Libellé;Montant;Référence
01/10/2026;CB CARREFOUR 0110;-42,10;OP20001
02/10/2026;PRLV SEPA EDF ECH 021026;-64,20;OP20004
03/10/2026;PRLV SEPA EDF ECH 021026;-64,20;OP20004
`

// ---------------------------------------------------------------------------
// OFX 1.0.2: SGML, and the leaf tags are not closed
// ---------------------------------------------------------------------------

FX_OFX :: `OFXHEADER:100
DATA:OFXSGML
VERSION:102
SECURITY:NONE
ENCODING:USASCII
CHARSET:1252
COMPRESSION:NONE
OLDFILEUID:NONE
NEWFILEUID:NONE

<OFX>
<SIGNONMSGSRSV1>
<SONRS>
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<DTSERVER>20261005120000[-5:EST]
<LANGUAGE>FRA
</SONRS>
</SIGNONMSGSRSV1>
<BANKMSGSRSV1>
<STMTTRNRS>
<TRNUID>1
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<STMTRS>
<CURDEF>EUR
<BANKACCTFROM>
<BANKID>99999
<ACCTID>FR7699999000010000001234537
<ACCTTYPE>CHECKING
</BANKACCTFROM>
<BANKTRANLIST>
<DTSTART>20260901000000
<DTEND>20260930235959
<STMTTRN>
<TRNTYPE>CREDIT
<DTPOSTED>20260902120000[-5:EST]
<TRNAMT>2450.00
<FITID>FX2026090200001
<NAME>VIR SALAIRE SOCIETE EXEMPLE SA
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260903120000[-5:EST]
<TRNAMT>-950.00
<FITID>FX2026090300002
<NAME>PRLV SEPA LOYER AGENCE EXEMPLE
<MEMO>ECH 030926
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260904120000[-5:EST]
<TRNAMT>-82.40
<FITID>FX2026090400003
<NAME>CB CARREFOUR 0409
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260905120000[-5:EST]
<TRNAMT>-64.20
<FITID>FX2026090500004
<NAME>PRLV SEPA EDF ECH 050926
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260911120000[-5:EST]
<TRNAMT>-13.49
<FITID>FX2026091100005
<NAME>PRLV SEPA NETFLIX 110926
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260911120000[-5:EST]
<TRNAMT>-13.49
<FITID>FX2026091100005
<NAME>PRLV SEPA NETFLIX 110926 (doublon)
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260921120000[-5:EST]
<TRNAMT>-91.25
<FITID>FX2026092100006
<NAME>CB CARREFOUR 2109
<MEMO>PAIEMENT PAR CARTE &amp; SANS CONTACT
</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL>
<BALAMT>1581.03
<DTASOF>20260930120000
</LEDGERBAL>
</STMTRS>
</STMTTRNRS>
</BANKMSGSRSV1>
</OFX>
`

// OFX 2.x: the same content as real XML, with every tag closed. The parser
// must read both with one code path.
FX_OFX_XML :: `<?xml version="1.0" encoding="UTF-8"?>
<?OFX OFXHEADER="200" VERSION="211" SECURITY="NONE" OLDFILEUID="NONE" NEWFILEUID="NONE"?>
<OFX>
  <BANKMSGSRSV1>
    <STMTTRNRS>
      <STMTRS>
        <CURDEF>EUR</CURDEF>
        <BANKACCTFROM>
          <BANKID>99999</BANKID>
          <ACCTID>FR7699999000010000006789048</ACCTID>
          <ACCTTYPE>SAVINGS</ACCTTYPE>
        </BANKACCTFROM>
        <BANKTRANLIST>
          <STMTTRN>
            <TRNTYPE>CREDIT</TRNTYPE>
            <DTPOSTED>20260917000000</DTPOSTED>
            <TRNAMT>200.00</TRNAMT>
            <FITID>XML2026091700001</FITID>
            <NAME>VIR M EXEMPLE EPARGNE</NAME>
          </STMTTRN>
          <STMTTRN>
            <TRNTYPE>CREDIT</TRNTYPE>
            <DTPOSTED>20261017000000</DTPOSTED>
            <TRNAMT>200.00</TRNAMT>
            <FITID>XML2026101700002</FITID>
            <NAME>VIR M EXEMPLE EPARGNE</NAME>
          </STMTTRN>
        </BANKTRANLIST>
        <LEDGERBAL>
          <BALAMT>5400.00</BALAMT>
          <DTASOF>20261031000000</DTASOF>
        </LEDGERBAL>
      </STMTRS>
    </STMTTRNRS>
  </BANKMSGSRSV1>
</OFX>
`

// Truncated: the download stopped inside a transaction. The rows before it
// are perfectly good and must still be imported.
FX_OFX_TRUNCATED :: `OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX>
<BANKMSGSRSV1>
<STMTTRNRS>
<STMTRS>
<CURDEF>EUR
<BANKACCTFROM>
<ACCTID>FR7699999000010000001234537
</BANKACCTFROM>
<BANKTRANLIST>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20261001120000
<TRNAMT>-42.10
<FITID>TRUNC001
<NAME>CB CARREFOUR 0110
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>2026100`

// ---------------------------------------------------------------------------
// CAMT.053, ISO 20022
// ---------------------------------------------------------------------------

FX_CAMT :: `<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
  <BkToCstmrStmt>
    <GrpHdr>
      <MsgId>EXEMPLE-20261005</MsgId>
      <CreDtTm>2026-10-05T06:00:00</CreDtTm>
    </GrpHdr>
    <Stmt>
      <Id>STMT-2026-10</Id>
      <CreDtTm>2026-10-05T06:00:00</CreDtTm>
      <Acct>
        <Id>
          <IBAN>FR7699999000010000001234537</IBAN>
        </Id>
        <Ccy>EUR</Ccy>
        <Ownr>
          <Nm>TITULAIRE EXEMPLE</Nm>
        </Ownr>
      </Acct>
      <Bal>
        <Tp><CdOrPrtry><Cd>PRCD</Cd></CdOrPrtry></Tp>
        <Amt Ccy="EUR">1581.03</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <Dt><Dt>2026-09-30</Dt></Dt>
      </Bal>
      <Bal>
        <Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp>
        <Amt Ccy="EUR">2832.89</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <Dt><Dt>2026-10-04</Dt></Dt>
      </Bal>
      <Ntry>
        <NtryRef>NTRY-0001</NtryRef>
        <Amt Ccy="EUR">4.80</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>2026-10-01</Dt></BookgDt>
        <ValDt><Dt>2026-10-01</Dt></ValDt>
        <NtryDtls>
          <TxDtls>
            <RmtInf><Ustrd>CB LE PETIT CAFE 1011</Ustrd></RmtInf>
            <RltdPties><Cdtr><Nm>LE PETIT CAFE EXEMPLE</Nm></Cdtr></RltdPties>
          </TxDtls>
        </NtryDtls>
      </Ntry>
      <Ntry>
        <NtryRef>NTRY-0002</NtryRef>
        <Amt Ccy="EUR">2450.00</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <BookgDt><Dt>2026-10-01</Dt></BookgDt>
        <NtryDtls>
          <TxDtls>
            <RmtInf><Ustrd>VIR SALAIRE SOCIETE EXEMPLE SA</Ustrd></RmtInf>
            <RltdPties><Dbtr><Nm>SOCIETE EXEMPLE SA</Nm></Dbtr></RltdPties>
          </TxDtls>
        </NtryDtls>
      </Ntry>
      <Ntry>
        <NtryRef>NTRY-0003</NtryRef>
        <Amt Ccy="EUR">950.00</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <BookgDt><Dt>2026-10-02</Dt></BookgDt>
        <NtryDtls>
          <TxDtls>
            <RmtInf><Ustrd>PRLV SEPA LOYER AGENCE EXEMPLE</Ustrd><Ustrd>ECH 021026</Ustrd></RmtInf>
          </TxDtls>
        </NtryDtls>
      </Ntry>
      <Ntry>
        <NtryRef>NTRY-0004</NtryRef>
        <Amt Ccy="EUR">64.20</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <BookgDt><Dt>2026-10-03</Dt></BookgDt>
        <AddtlNtryInf>PRLV SEPA EDF ECH 031026 MDT 5512</AddtlNtryInf>
      </Ntry>
      <Ntry>
        <NtryRef>NTRY-0005</NtryRef>
        <Amt Ccy="EUR">19.99</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <BookgDt><Dt>2026-10-04</Dt></BookgDt>
        <NtryDtls>
          <TxDtls>
            <RmtInf><Ustrd>PRLV SEPA FREE MOBILE 041026</Ustrd></RmtInf>
          </TxDtls>
        </NtryDtls>
      </Ntry>
    </Stmt>
  </BkToCstmrStmt>
</Document>
`

// A CAMT whose last entry has no CdtDbtInd. The sign of a CAMT amount is
// *only* in that element, so the entry has to be refused: guessing it would
// book a 300 € debit as 300 € of income.
FX_CAMT_NO_IND :: `<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
  <BkToCstmrStmt>
    <Stmt>
      <Acct><Id><IBAN>FR7699999000010000001234537</IBAN></Id></Acct>
      <Ntry>
        <NtryRef>NOIND-0001</NtryRef>
        <Amt Ccy="EUR">12.00</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <BookgDt><Dt>2026-10-01</Dt></BookgDt>
        <AddtlNtryInf>CB BONNE LIGNE</AddtlNtryInf>
      </Ntry>
      <Ntry>
        <NtryRef>NOIND-0002</NtryRef>
        <Amt Ccy="EUR">300.00</Amt>
        <BookgDt><Dt>2026-10-02</Dt></BookgDt>
        <AddtlNtryInf>CB LIGNE SANS INDICATEUR</AddtlNtryInf>
      </Ntry>
    </Stmt>
  </BkToCstmrStmt>
</Document>
`

// Truncated mid-element.
FX_CAMT_TRUNCATED :: `<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
  <BkToCstmrStmt>
    <Stmt>
      <Acct><Id><IBAN>FR7699999000010000001234537</IBAN></Id></Acct>
      <Ntry>
        <NtryRef>CUT-0001</NtryRef>
        <Amt Ccy="EUR">42.10</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <BookgDt><Dt>2026-10-01</Dt></BookgDt>
        <AddtlNtryInf>CB CARREFOUR 0110</AddtlNtryInf>
      </Ntry>
      <Ntry>
        <NtryRef>CUT-0002</NtryRef>
        <Amt Ccy="EUR">64.2`

// ---------------------------------------------------------------------------
// Writing them out
// ---------------------------------------------------------------------------

// to_latin1 is the inverse of the decoder, used only to produce the
// Windows-1252 fixture — a French bank export really does arrive like this,
// and a UTF-8-only importer renders `Libellé` as `Libell?`.
to_latin1 :: proc(s: string, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	for r in s {
		switch {
		case r < 0x100:
			append(&out, u8(r))
		case r == '€':
			append(&out, 0x80)
		case r == '’':
			append(&out, 0x92)
		case:
			append(&out, '?')
		}
	}
	return out[:]
}

FIXTURES := [?]struct {
	name:   string,
	body:   string,
	latin1: bool,
} {
	{"alpha-septembre.csv", FX_ALPHA_CSV, false},
	{"alpha-septembre-latin1.csv", FX_ALPHA_CSV, true},
	{"beta-octobre.csv", FX_BETA_CSV, false},
	{"gamma-sans-entete.csv", FX_GAMMA_CSV, false},
	{"malforme.csv", FX_BAD_CSV, false},
	{"doublons.csv", FX_DUP_CSV, false},
	{"alpha-septembre.ofx", FX_OFX, false},
	{"epargne.qfx", FX_OFX_XML, false},
	{"tronque.ofx", FX_OFX_TRUNCATED, false},
	{"octobre.camt.xml", FX_CAMT, false},
	{"sans-indicateur.camt.xml", FX_CAMT_NO_IND, false},
	{"tronque.camt.xml", FX_CAMT_TRUNCATED, false},
}

// fixtures_mode is `money --fixtures DIR`: write the fixtures where the
// caller asks. It writes nowhere by default and never into the store.
fixtures_mode :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("money: --fixtures needs a directory")
		return 2
	}
	dir := args[0]
	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			fmt.eprintfln("money: cannot create %s", dir)
			return 1
		}
	}
	n := 0
	for f in FIXTURES {
		path := fmt.tprintf("%s/%s", dir, f.name)
		data: []u8
		if f.latin1 {
			data = to_latin1(f.body, context.temp_allocator)
		} else {
			data = transmute([]u8)f.body
		}
		if werr := os.write_entire_file(path, data); werr != nil {
			fmt.eprintfln("money: cannot write %s", path)
			return 1
		}
		n += 1
	}
	fmt.printfln("%d fixtures written to %s", n, dir)
	return 0
}

// ---------------------------------------------------------------------------
// A synthetic book, for the demo and the benchmark
// ---------------------------------------------------------------------------

// A tiny deterministic generator. The same seed gives the same book on every
// machine, which is what makes a benchmark comparable and a test repeatable.
Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{seed | 1}
}

// xorshift64*, which is plenty for placing synthetic transactions.
rng_next :: proc(r: ^Rng) -> u64 {
	x := r.s
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	r.s = x
	return x * 0x2545F4914F6CDD1D
}

rng_int :: proc(r: ^Rng, lo, hi: int) -> int {
	if hi <= lo {
		return lo
	}
	return lo + int(rng_next(r) % u64(hi - lo + 1))
}

SHOPS := [?]string {
	"CARREFOUR",
	"LIDL",
	"MONOPRIX",
	"FRANPRIX",
	"BOULANGERIE DU COIN",
	"LE PETIT CAFE",
	"PHARMACIE CENTRALE",
	"DECATHLON",
	"FNAC",
	"AMAZON",
	"UBER EATS",
	"SNCF CONNECT",
	"RATP NAVIGO",
	"TOTAL ACCESS",
	"IKEA",
	"BIOCOOP",
}

// gen_history fills an account with `months` months of plausible noise plus
// four charges with *known* recurrences, which is what the recurrence test
// asserts against. The noise is there on purpose: finding a monthly charge in
// an otherwise empty book proves nothing.
gen_history :: proc(app: ^App, account: int, months: int, seed: u64 = 20261005) -> int {
	r := rng_make(seed)
	l := &app.led
	holding := l.unallocated
	added := 0

	add :: proc(l: ^Ledger, account, holding: int, d: Date, label: string, amount: Cents) -> bool {
		method, _ := label_method(label_normalize(label, context.temp_allocator))
		ents := [2]Entry{{account, amount}, {holding, -amount}}
		_, ok := txn_add(
			l,
			{date = d, label = label, method = method, entries = ents[:]},
		)
		return ok
	}

	start := date_month_add(month_start(app.today), -(months - 1))
	for k in 0 ..< months {
		m := date_month_add(start, k)

		// Nothing is booked after today: a statement does not contain next
		// week. Each charge is guarded on its own day rather than skipping
		// the whole month, or the current month would lose its card payments
		// as soon as today fell before the 11th.
		on :: proc(app: ^App, l: ^Ledger, account, holding: int, y, mm, d: int, label: string, amount: Cents) -> int {
			if date_less(app.today, Date{y, mm, d}) {
				return 0
			}
			method, _ := label_method(label_normalize(label, context.temp_allocator))
			ents := [2]Entry{{account, amount}, {holding, -amount}}
			if _, ok := txn_add(
				l,
				{date = Date{y, mm, d}, label = label, method = method, entries = ents[:]},
			); ok {
				return 1
			}
			return 0
		}

		// The known recurrences: a salary, a rent, an energy bill that drifts
		// by a few centimes, and a subscription at a fixed price.
		added += on(app, l, account, holding, m.y, m.m, 2, "VIR SALAIRE SOCIETE EXEMPLE SA", 245000)
		added += on(
			app,
			l,
			account,
			holding,
			m.y,
			m.m,
			3,
			fmt.tprintf("PRLV SEPA LOYER AGENCE EXEMPLE ECH %02d%02d%02d", 3, m.m, m.y % 100),
			-95000,
		)
		drift := Cents(rng_int(&r, -180, 180))
		added += on(
			app,
			l,
			account,
			holding,
			m.y,
			m.m,
			5,
			fmt.tprintf("PRLV SEPA EDF ECH %02d%02d%02d MDT 5512", 5, m.m, m.y % 100),
			-6420 + drift,
		)
		added += on(app, l, account, holding, m.y, m.m, 11, "PRLV SEPA NETFLIX", -1349)

		// Noise: card payments through the month at synthetic amounts. The
		// last month stops at today — a statement does not contain next
		// week's shopping, and a demo that shows future card payments reads
		// as fiction rather than as an example.
		last_day := days_in_month(m.y, m.m)
		if m.y == app.today.y && m.m == app.today.m {
			last_day = app.today.d
		}
		n := rng_int(&r, 12, 22)
		for _ in 0 ..< n {
			day := rng_int(&r, 1, last_day)
			shop := SHOPS[rng_int(&r, 0, len(SHOPS) - 1)]
			amount := Cents(rng_int(&r, 250, 7000))
			label := fmt.tprintf("CB %s %02d%02d", shop, day, m.m)
			if add(l, account, holding, Date{m.y, m.m, day}, label, -amount) {
				added += 1
			}
		}
		_ = last_day
	}

	// The near-misses, which the recurrence detector must *not* report.
	//
	//   * three charges from the same shop at the same amount, but at
	//     irregular intervals — a coincidence, not a subscription;
	//   * two charges a month apart — a pair is not a cadence;
	//   * three monthly charges whose amounts vary by 40 % — the same shop
	//     every month is not a fixed commitment.
	base := month_start(app.today)
	add(l, account, holding, date_add(base, -200), "CB GARAGE EXEMPLE", -8900)
	add(l, account, holding, date_add(base, -140), "CB GARAGE EXEMPLE", -8900)
	add(l, account, holding, date_add(base, -20), "CB GARAGE EXEMPLE", -8900)

	add(l, account, holding, date_month_add(base, -2), "PRLV SEPA CLUB EXEMPLE", -2500)
	add(l, account, holding, date_month_add(base, -1), "PRLV SEPA CLUB EXEMPLE", -2500)

	add(l, account, holding, date_month_add(Date{base.y, base.m, 9}, -3), "CB ATELIER EXEMPLE", -3000)
	add(l, account, holding, date_month_add(Date{base.y, base.m, 9}, -2), "CB ATELIER EXEMPLE", -4800)
	add(l, account, holding, date_month_add(Date{base.y, base.m, 9}, -1), "CB ATELIER EXEMPLE", -1900)
	added += 8

	return added
}

// seed_demo builds the book the application opens with on a machine that has
// no data yet, and the book the demo recording drives. Everything in it comes
// from this file, so it is fictitious by construction.
seed_demo :: proc(app: ^App) {
	ensure_categories(app)
	current := account_add(&app.led, "Compte courant", .Asset, FX_IBAN_CURRENT, "Banque Alpha")
	savings := account_add(&app.led, "Livret", .Asset, FX_IBAN_SAVINGS, "Banque Alpha")

	opening_balance(&app.led, current, 120000, date_add(date_month_add(month_start(app.today), -8), -1))
	opening_balance(&app.led, savings, 520000, date_add(date_month_add(month_start(app.today), -8), -1))

	gen_history(app, current, 8)
	apply_rules(&app.led, &app.cat)

	// A couple of transfers to savings, so the ledger has something that is
	// movement rather than spending.
	for k in 1 ..= 3 {
		m := date_month_add(month_start(app.today), -k)
		transfer_add(&app.led, current, savings, 20000, Date{m.y, m.m, 17}, "VIR M EXEMPLE EPARGNE")
	}
	_ = savings

	// Budgets for this month, suggested from the history that was just
	// generated — which is also the honest way to set a first budget.
	for c in category_list(app) {
		if app.led.accounts[c].kind != .Expense {
			continue
		}
		if s := budget_suggest(app, c, app.month.y, app.month.m); s > 0 {
			budget_set(app, c, app.month.y, app.month.m, s, true)
		}
	}
	app.filter.account = current
	app.recs_stale = true
	refilter(app)
}

_ :: strings
