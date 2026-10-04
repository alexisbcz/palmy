// The catalogue.
//
// This is generated, and it says so everywhere it is shown. Nothing in this
// binary reads a retailer's website: Kiabi, Bershka, Celio, Intermarché,
// E.Leclerc and Carrefour all prohibit automated access in their terms, a
// scraper breaks the week after it is written, and an agent hammering them
// could get this machine's address blocked. None of that is needed to build
// and prove the thing that is actually hard here — the unit price, the
// Nutri-Score, the integer money, the size tables — and a generated catalogue
// is *better* for that, because it is ground truth: the price of a 500 g jar
// and the price of a 750 g jar are known exactly, so the €/kg they imply is
// known exactly too.
//
// The shape of the data is real, though. Prices are derived from a plausible
// price per kilo or per litre and then jittered per chain, so a lot of six is
// cheaper per litre than a single bottle, a store brand undercuts the national
// brand, and the cheapest sticker is regularly not the cheapest kilo. The
// nutrition values are the published ones for the products these are modelled
// on, which is why the famous grades come out right: Coca-Cola E, pure orange
// juice C, Emmental D, olive oil D, butter E, semi-skimmed milk B.
//
// No personal data appears anywhere in here. There are no accounts, no
// addresses and no names.
package main

import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// A tiny deterministic generator
//
// The same seed gives the same catalogue on every machine, which is what lets
// the self-test assert a basket total to the centime.
// ---------------------------------------------------------------------------

Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{s = seed == 0 ? 0x9e3779b97f4a7c15 : seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	x := r.s
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.s = x
	return x * 0x2545f4914f6cdd1d
}

// rng_range is inclusive at both ends.
rng_range :: proc(r: ^Rng, lo, hi: i64) -> i64 {
	if hi <= lo {
		return lo
	}
	return lo + i64(rng_next(r) % u64(hi - lo + 1))
}

rng_chance :: proc(r: ^Rng, percent: i64) -> bool {
	return rng_range(r, 1, 100) <= percent
}

// ---------------------------------------------------------------------------
// Grocery templates
//
// `per` is the price of a kilo, a litre or a piece, in centimes, before the
// per-chain jitter. `n` is the nutrition declaration per 100 g or 100 ml:
// energy in kJ, then sugars, saturated fat, total fat in milligrams, sodium in
// milligrams, then fibre and protein in milligrams, then the fruit, vegetable
// and legume percentage. An energy of zero means the product carries no
// nutrition declaration, which is correct for soap.
// ---------------------------------------------------------------------------

Nut :: struct {
	kj, sug, sat, fat, sod, fib, pro, fru: i64,
}

G :: struct {
	name:     string,
	brand:    string, // "" is a marque de distributeur
	aisle:    Aisle,
	class:    Food_Class,
	tva:      Tva,
	per:      i64,
	variants: string, // quantity texts, '|' separated
	own:      bool,   // a store-brand version is generated alongside
	n:        Nut,
}

// Milk and drinkable dairy are scored on the general table, not the beverage
// one — in the 2017 scheme "boissons" means waters, sodas, juices and nectars.
// That is why semi-skimmed milk comes out a B here rather than an E.
GROCERY := [?]G {
	// --- Crèmerie -----------------------------------------------------------
	{"Lait demi-écrémé UHT", "Lactel", .Cremerie, .Solid, .Food, 110,
	 "1 L|lot de 6 x 1 L|lot de 12 x 1 L", true, {196, 4800, 900, 1550, 40, 0, 3200, 0}},
	{"Lait entier UHT", "Candia", .Cremerie, .Solid, .Food, 120,
	 "1 L|lot de 6 x 1 L", true, {272, 4800, 2300, 3600, 40, 0, 3200, 0}},
	{"Lait écrémé UHT", "Lactel", .Cremerie, .Solid, .Food, 105,
	 "1 L|lot de 6 x 1 L", false, {142, 4800, 60, 100, 40, 0, 3300, 0}},
	{"Beurre doux", "Président", .Cremerie, .Added_Fat, .Food, 1150,
	 "250 g|500 g", true, {3060, 600, 54000, 82000, 10, 0, 700, 0}},
	{"Beurre demi-sel", "Elle & Vire", .Cremerie, .Added_Fat, .Food, 1230,
	 "250 g", false, {3040, 600, 54000, 82000, 600, 0, 700, 0}},
	{"Emmental râpé", "Entremont", .Cremerie, .Cheese, .Food, 1250,
	 "200 g|400 g", true, {1600, 0, 20000, 29000, 320, 0, 28000, 0}},
	{"Camembert au lait pasteurisé", "Coeur de Lion", .Cremerie, .Cheese, .Food, 980,
	 "250 g", true, {1240, 500, 15000, 22000, 700, 0, 20000, 0}},
	{"Comté affiné 12 mois", "Juraflore", .Cremerie, .Cheese, .Food, 2290,
	 "200 g|350 g", false, {1700, 500, 21000, 34000, 320, 0, 27000, 0}},
	{"Yaourt nature", "Danone", .Cremerie, .Solid, .Food, 185,
	 "lot de 4 x 125 g|lot de 8 x 125 g|lot de 16 x 125 g", true, {205, 4600, 700, 1200, 60, 0, 4000, 0}},
	{"Yaourt aux fruits", "Yoplait", .Cremerie, .Solid, .Food, 230,
	 "lot de 4 x 125 g|lot de 12 x 125 g", true, {380, 12500, 900, 1500, 50, 300, 3300, 8}},
	{"Fromage blanc 3 % MG", "Danone", .Cremerie, .Solid, .Food, 260,
	 "500 g|1 kg", true, {310, 4300, 1900, 3000, 50, 0, 7500, 0}},
	{"Crème fraîche épaisse 30 %", "Isigny", .Cremerie, .Solid, .Food, 520,
	 "20 cl|50 cl", true, {1240, 2800, 20000, 30000, 40, 0, 2300, 0}},
	{"Oeufs frais de poules élevées en plein air", "Matines", .Cremerie, .Solid, .Food, 38,
	 "6 pieces|12 pieces", true, {565, 400, 2900, 9800, 140, 0, 12600, 0}},
	{"Mozzarella di Bufala", "Galbani", .Cremerie, .Cheese, .Food, 1490,
	 "125 g|250 g", false, {1090, 800, 11000, 20000, 300, 0, 17000, 0}},
	{"Chèvre bûche", "Soignon", .Cremerie, .Cheese, .Food, 1390,
	 "180 g", false, {1180, 1000, 15000, 22000, 480, 0, 17000, 0}},

	// --- Épicerie salée -----------------------------------------------------
	{"Pâtes Penne", "Panzani", .Epicerie_Salee, .Solid, .Food, 185,
	 "500 g|1 kg|lot de 3 x 500 g", true, {1490, 3000, 300, 1500, 10, 3000, 12500, 0}},
	{"Pâtes Spaghetti", "Barilla", .Epicerie_Salee, .Solid, .Food, 215,
	 "500 g|1 kg", true, {1490, 3500, 300, 1500, 10, 3000, 12000, 0}},
	{"Coquillettes", "Panzani", .Epicerie_Salee, .Solid, .Food, 175,
	 "500 g|1 kg", true, {1490, 3000, 300, 1500, 10, 3000, 12500, 0}},
	{"Riz long grain", "Taureau Ailé", .Epicerie_Salee, .Solid, .Food, 265,
	 "500 g|1 kg", true, {1480, 100, 200, 900, 5, 1400, 7500, 0}},
	{"Riz basmati", "Taureau Ailé", .Epicerie_Salee, .Solid, .Food, 390,
	 "500 g|1 kg", false, {1470, 100, 200, 800, 5, 1300, 8100, 0}},
	{"Lentilles vertes", "Vivien Paille", .Epicerie_Salee, .Solid, .Food, 310,
	 "500 g|1 kg", true, {1340, 1200, 200, 1100, 10, 11000, 24000, 100}},
	{"Pois chiches", "Cassegrain", .Epicerie_Salee, .Solid, .Food, 290,
	 "400 g|lot de 3 x 400 g", true, {490, 800, 300, 2300, 240, 5200, 6300, 100}},
	{"Huile d'olive vierge extra", "Puget", .Epicerie_Salee, .Added_Fat, .Food, 980,
	 "50 cl|75 cl|1 L", true, {3700, 0, 14000, 100000, 0, 0, 0, 100}},
	{"Huile de tournesol", "Lesieur", .Epicerie_Salee, .Added_Fat, .Food, 285,
	 "1 L|lot de 2 x 1 L", true, {3700, 0, 11000, 100000, 0, 0, 0, 0}},
	{"Vinaigre balsamique", "Maille", .Epicerie_Salee, .Solid, .Food, 650,
	 "50 cl", false, {480, 17000, 0, 0, 10, 0, 500, 0}},
	{"Moutarde de Dijon", "Maille", .Epicerie_Salee, .Solid, .Food, 420,
	 "370 g", true, {600, 2500, 500, 9000, 2400, 4000, 7000, 0}},
	{"Ketchup", "Heinz", .Epicerie_Salee, .Solid, .Standard, 380,
	 "570 g|lot de 2 x 570 g", true, {480, 22800, 0, 100, 720, 1000, 1200, 85}},
	{"Mayonnaise", "Amora", .Epicerie_Salee, .Solid, .Standard, 520,
	 "475 g", true, {2800, 1500, 5500, 73000, 900, 0, 1300, 0}},
	{"Sauce tomate basilic", "Panzani", .Epicerie_Salee, .Solid, .Food, 310,
	 "400 g|lot de 3 x 400 g", true, {230, 4400, 200, 1500, 320, 1600, 1300, 90}},
	{"Thon au naturel", "Petit Navire", .Epicerie_Salee, .Solid, .Food, 1390,
	 "140 g|lot de 3 x 140 g", true, {440, 0, 200, 600, 400, 0, 25000, 0}},
	{"Sardines à l'huile d'olive", "Connétable", .Epicerie_Salee, .Solid, .Food, 1590,
	 "115 g", false, {870, 0, 3000, 14000, 480, 0, 23000, 0}},
	{"Maïs doux", "Géant Vert", .Epicerie_Salee, .Solid, .Food, 340,
	 "300 g|lot de 3 x 150 g", true, {380, 5000, 100, 900, 200, 3000, 2600, 100}},
	{"Haricots verts extra-fins", "Cassegrain", .Epicerie_Salee, .Solid, .Food, 410,
	 "440 g|lot de 2 x 440 g", true, {120, 1500, 0, 200, 240, 3200, 1400, 100}},
	{"Soupe de légumes", "Liebig", .Epicerie_Salee, .Solid, .Food, 220,
	 "1 L|lot de 2 x 1 L", true, {130, 2000, 100, 500, 280, 1300, 800, 95}},
	{"Bouillon de volaille", "Maggi", .Epicerie_Salee, .Solid, .Food, 85,
	 "12 pieces", false, {830, 1500, 2500, 5000, 17000, 0, 7000, 0}},
	{"Sel fin de Guérande", "Le Paludier", .Epicerie_Salee, .Solid, .Food, 290,
	 "500 g|1 kg", false, {0, 0, 0, 0, 38000, 0, 0, 0}},
	{"Couscous moyen", "Ferrero", .Epicerie_Salee, .Solid, .Food, 230,
	 "500 g|1 kg", true, {1480, 900, 200, 1400, 10, 4300, 12000, 0}},
	{"Quinoa", "Tipiak", .Epicerie_Salee, .Solid, .Food, 820,
	 "400 g", false, {1510, 2000, 700, 6100, 10, 7000, 14000, 0}},
	{"Chips nature", "Lay's", .Epicerie_Salee, .Solid, .Standard, 980,
	 "150 g|lot de 3 x 150 g", true, {2230, 500, 3400, 31000, 480, 4200, 6000, 0}},
	{"Cacahuètes grillées salées", "Daco", .Epicerie_Salee, .Solid, .Standard, 760,
	 "400 g", false, {2490, 4700, 8000, 49000, 500, 8000, 26000, 100}},

	// --- Épicerie sucrée ----------------------------------------------------
	{"Sucre en poudre", "Daddy", .Epicerie_Sucree, .Solid, .Food, 115,
	 "1 kg|lot de 2 x 1 kg", true, {1700, 100000, 0, 0, 0, 0, 0, 0}},
	{"Farine de blé T55", "Francine", .Epicerie_Sucree, .Solid, .Food, 98,
	 "1 kg|lot de 3 x 1 kg", true, {1450, 1500, 200, 1000, 10, 3000, 10000, 0}},
	{"Confiture de fraises", "Bonne Maman", .Epicerie_Sucree, .Solid, .Food, 630,
	 "370 g|750 g", true, {930, 54000, 0, 0, 10, 1000, 400, 55}},
	{"Confiture d'abricots", "Bonne Maman", .Epicerie_Sucree, .Solid, .Food, 630,
	 "370 g|750 g", false, {940, 55000, 0, 0, 10, 1000, 400, 55}},
	{"Miel de fleurs", "Lune de Miel", .Epicerie_Sucree, .Solid, .Food, 1180,
	 "500 g", true, {1380, 80000, 0, 0, 10, 0, 300, 0}},
	{"Pâte à tartiner noisettes", "Nutella", .Epicerie_Sucree, .Solid, .Food, 720,
	 "400 g|750 g|lot de 2 x 400 g", true, {2273, 56300, 10600, 30900, 15, 0, 6300, 0}},
	{"Chocolat noir 70 % cacao", "Lindt", .Epicerie_Sucree, .Solid, .Food, 1690,
	 "100 g|lot de 2 x 100 g", true, {2400, 29000, 21000, 41000, 10, 11000, 9000, 0}},
	{"Chocolat au lait", "Milka", .Epicerie_Sucree, .Solid, .Food, 1190,
	 "100 g|200 g", true, {2250, 56000, 17000, 30000, 170, 2000, 6600, 0}},
	{"Biscuits Petit Beurre", "LU", .Epicerie_Sucree, .Solid, .Food, 520,
	 "200 g|lot de 2 x 200 g", true, {1850, 22000, 4800, 12000, 400, 2600, 7500, 0}},
	{"Biscuits sablés", "St Michel", .Epicerie_Sucree, .Solid, .Food, 590,
	 "150 g", false, {2010, 25000, 10000, 19000, 380, 2000, 6000, 0}},
	{"Céréales pétales de maïs", "Kellogg's", .Epicerie_Sucree, .Solid, .Food, 480,
	 "375 g|750 g", true, {1600, 8000, 100, 900, 540, 3000, 7000, 0}},
	{"Muesli aux fruits secs", "Jordans", .Epicerie_Sucree, .Solid, .Food, 650,
	 "500 g", true, {1620, 17000, 1700, 11000, 30, 7500, 9000, 30}},
	{"Café moulu arabica", "Carte Noire", .Epicerie_Sucree, .Solid, .Food, 1450,
	 "250 g|lot de 2 x 250 g", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Capsules café intense", "L'Or", .Epicerie_Sucree, .Solid, .Food, 32,
	 "10 capsules|lot de 5 x 10 capsules", false, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Thé vert menthe", "Lipton", .Epicerie_Sucree, .Solid, .Food, 45,
	 "25 sachets|lot de 2 x 25 sachets", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Compote de pommes sans sucres ajoutés", "Materne", .Epicerie_Sucree, .Solid, .Food, 310,
	 "lot de 4 x 100 g|lot de 12 x 100 g", true, {210, 11000, 0, 100, 10, 1300, 300, 100}},

	// --- Boissons -----------------------------------------------------------
	{"Eau de source", "Cristaline", .Boissons, .Water, .Food, 24,
	 "1,5 L|lot de 6 x 1,5 L", true, {0, 0, 0, 0, 1, 0, 0, 0}},
	{"Eau minérale naturelle", "Evian", .Boissons, .Water, .Food, 58,
	 "1 L|lot de 6 x 1,5 L", false, {0, 0, 0, 0, 2, 0, 0, 0}},
	{"Eau gazeuse", "Badoit", .Boissons, .Water, .Food, 72,
	 "1,25 L|lot de 6 x 1,25 L", false, {0, 0, 0, 0, 65, 0, 0, 0}},
	{"Cola", "Coca-Cola", .Boissons, .Beverage, .Food, 155,
	 "1,5 L|lot de 6 x 33 cl|lot de 12 x 33 cl", true, {180, 10600, 0, 0, 5, 0, 0, 0}},
	{"Cola sans sucres", "Coca-Cola", .Boissons, .Beverage, .Food, 155,
	 "1,5 L|lot de 6 x 33 cl", false, {2, 0, 0, 0, 10, 0, 0, 0}},
	{"Limonade", "Lorina", .Boissons, .Beverage, .Food, 170,
	 "75 cl|lot de 4 x 25 cl", false, {160, 9200, 0, 0, 3, 0, 0, 0}},
	{"Jus d'orange sans pulpe 100 % pur jus", "Tropicana", .Boissons, .Beverage, .Food, 220,
	 "1 L|lot de 3 x 1 L", true, {180, 9000, 0, 0, 2, 200, 700, 100}},
	{"Jus de pomme", "Andros", .Boissons, .Beverage, .Food, 185,
	 "1 L|lot de 6 x 1 L", true, {192, 10500, 0, 0, 2, 100, 100, 100}},
	{"Nectar multifruits", "Joker", .Boissons, .Beverage, .Food, 145,
	 "1 L|lot de 6 x 1 L", true, {200, 11000, 0, 0, 3, 200, 300, 50}},
	{"Sirop de grenadine", "Teisseire", .Boissons, .Beverage, .Food, 320,
	 "75 cl", false, {290, 17000, 0, 0, 5, 0, 0, 0}},
	{"Bière blonde", "Kronenbourg", .Boissons, .Beverage, .Standard, 240,
	 "lot de 6 x 25 cl|lot de 12 x 25 cl|lot de 20 x 25 cl", true, {160, 2700, 0, 0, 4, 0, 400, 0}},
	{"Bière blonde premium", "1664", .Boissons, .Beverage, .Standard, 300,
	 "lot de 6 x 33 cl|lot de 12 x 33 cl", false, {170, 2800, 0, 0, 4, 0, 400, 0}},
	{"Cidre brut", "Loïc Raison", .Boissons, .Beverage, .Standard, 290,
	 "75 cl", false, {190, 3000, 0, 0, 5, 0, 100, 0}},

	// --- Boucherie, poissonnerie -------------------------------------------
	{"Blanc de poulet", "Le Gaulois", .Boucherie, .Solid, .Food, 1180,
	 "400 g|800 g", true, {460, 0, 400, 1400, 320, 0, 23000, 0}},
	{"Cuisses de poulet", "Maître Coq", .Boucherie, .Solid, .Food, 590,
	 "1 kg", true, {700, 0, 1800, 7000, 280, 0, 19000, 0}},
	{"Steak haché pur boeuf 5 %", "Charal", .Boucherie, .Solid, .Food, 1450,
	 "lot de 2 x 125 g|lot de 4 x 125 g", true, {520, 0, 2300, 5000, 300, 0, 20000, 0}},
	{"Jambon blanc", "Herta", .Boucherie, .Solid, .Food, 1520,
	 "4 tranches|12 tranches", true, {480, 900, 1200, 3000, 920, 0, 19000, 0}},
	{"Saucisson sec", "Justin Bridou", .Boucherie, .Solid, .Food, 2290,
	 "200 g", false, {1700, 1000, 14000, 35000, 1800, 0, 25000, 0}},
	{"Lardons fumés", "Herta", .Boucherie, .Solid, .Food, 1180,
	 "200 g|lot de 2 x 200 g", true, {1100, 500, 9000, 21000, 1400, 0, 17000, 0}},
	{"Saumon fumé d'Atlantique", "Labeyrie", .Poissonnerie, .Solid, .Food, 3390,
	 "100 g|200 g", true, {800, 0, 2500, 12000, 1200, 0, 22000, 0}},
	{"Filets de cabillaud", "Findus", .Poissonnerie, .Solid, .Food, 1890,
	 "400 g", true, {330, 0, 200, 700, 240, 0, 18000, 0}},
	{"Crevettes décortiquées", "Gel Pêche", .Poissonnerie, .Solid, .Food, 2490,
	 "200 g", false, {400, 0, 200, 1000, 1100, 0, 20000, 0}},

	// --- Fruits et légumes --------------------------------------------------
	{"Pommes Golden", "", .Fruits_Legumes, .Solid, .Food, 235,
	 "1 kg|lot de 6 pieces", false, {220, 10400, 0, 100, 1, 2400, 300, 100}},
	{"Bananes", "", .Fruits_Legumes, .Solid, .Food, 195,
	 "1 kg", false, {380, 15800, 100, 300, 1, 2600, 1100, 100}},
	{"Oranges à jus", "", .Fruits_Legumes, .Solid, .Food, 215,
	 "2 kg", false, {200, 9000, 0, 100, 1, 2200, 1000, 100}},
	{"Tomates grappe", "", .Fruits_Legumes, .Solid, .Food, 289,
	 "500 g|1 kg", false, {80, 2600, 0, 200, 5, 1200, 800, 100}},
	{"Carottes", "", .Fruits_Legumes, .Solid, .Food, 135,
	 "1 kg|2 kg", false, {150, 4700, 0, 200, 60, 2800, 700, 100}},
	{"Pommes de terre à chair ferme", "", .Fruits_Legumes, .Solid, .Food, 115,
	 "2,5 kg|5 kg", false, {320, 800, 0, 100, 5, 2200, 2000, 100}},
	{"Courgettes", "", .Fruits_Legumes, .Solid, .Food, 245,
	 "1 kg", false, {70, 2200, 0, 300, 10, 1100, 1200, 100}},
	{"Salade batavia", "", .Fruits_Legumes, .Solid, .Food, 115,
	 "1 piece", false, {60, 1000, 0, 200, 10, 1300, 1200, 100}},
	{"Oignons jaunes", "", .Fruits_Legumes, .Solid, .Food, 145,
	 "1 kg", false, {170, 5000, 0, 100, 3, 1700, 1200, 100}},
	{"Bananes bio", "", .Fruits_Legumes, .Solid, .Food, 265,
	 "1 kg", false, {380, 15800, 100, 300, 1, 2600, 1100, 100}},

	// --- Boulangerie --------------------------------------------------------
	{"Baguette tradition", "", .Boulangerie, .Solid, .Food, 125,
	 "1 piece", false, {1120, 1500, 300, 1200, 480, 3000, 8500, 0}},
	{"Pain de mie complet", "Harrys", .Boulangerie, .Solid, .Food, 380,
	 "500 g", true, {1030, 4000, 700, 3500, 440, 5500, 9000, 0}},
	{"Croissants pur beurre", "", .Boulangerie, .Solid, .Food, 95,
	 "lot de 4 pieces|lot de 6 pieces", false, {1800, 9000, 14000, 24000, 450, 2000, 7000, 0}},
	{"Brioche tranchée", "Pasquier", .Boulangerie, .Solid, .Food, 420,
	 "500 g", true, {1540, 15000, 5000, 13000, 400, 2000, 8000, 0}},

	// --- Surgelés -----------------------------------------------------------
	{"Pizza 4 fromages surgelée", "Buitoni", .Surgeles, .Solid, .Food, 740,
	 "350 g|lot de 2 x 350 g", true, {1030, 3000, 6000, 11000, 600, 2000, 11000, 10}},
	{"Frites surgelées", "McCain", .Surgeles, .Solid, .Food, 215,
	 "1 kg|2,5 kg", true, {640, 400, 500, 4500, 60, 2500, 2500, 90}},
	{"Épinards hachés surgelés", "Bonduelle", .Surgeles, .Solid, .Food, 265,
	 "750 g", true, {120, 500, 100, 400, 80, 2600, 2900, 100}},
	{"Glace vanille", "Carte d'Or", .Surgeles, .Solid, .Food, 480,
	 "1 L|lot de 2 x 50 cl", true, {840, 21000, 6000, 10000, 60, 0, 3000, 0}},
	{"Poêlée de légumes surgelée", "Bonduelle", .Surgeles, .Solid, .Food, 310,
	 "750 g", true, {180, 2500, 100, 500, 100, 2800, 2200, 100}},

	// --- Hygiène, entretien, bébé ------------------------------------------
	{"Dentifrice protection caries", "Signal", .Hygiene, .Solid, .Standard, 185,
	 "75 ml|lot de 2 x 75 ml", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Gel douche hydratant", "Dove", .Hygiene, .Solid, .Standard, 440,
	 "250 ml|500 ml", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Shampooing cheveux normaux", "Garnier", .Hygiene, .Solid, .Standard, 520,
	 "250 ml|lot de 2 x 250 ml", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Déodorant 48 h", "Narta", .Hygiene, .Solid, .Standard, 980,
	 "200 ml", false, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Papier toilette double épaisseur", "Lotus", .Hygiene, .Solid, .Standard, 68,
	 "6 rouleaux|12 rouleaux|24 rouleaux", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Lessive liquide", "Ariel", .Entretien, .Solid, .Standard, 680,
	 "1,5 L|2,145 L|3 L", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Liquide vaisselle", "Paic", .Entretien, .Solid, .Standard, 290,
	 "500 ml|750 ml", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Nettoyant multi-usages", "Ajax", .Entretien, .Solid, .Standard, 185,
	 "1 L|lot de 2 x 1 L", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Sacs poubelle 30 L", "Handy Bag", .Entretien, .Solid, .Standard, 22,
	 "20 pieces|lot de 2 x 20 pieces", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Couches taille 4", "Pampers", .Bebe, .Solid, .Standard, 28,
	 "50 pieces|lot de 2 x 50 pieces", true, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Lait infantile 2e âge", "Gallia", .Bebe, .Solid, .Food, 1680,
	 "800 g", false, {0, 0, 0, 0, 0, 0, 0, 0}},
	{"Petit pot légumes carottes", "Blédina", .Bebe, .Solid, .Food, 480,
	 "lot de 2 x 130 g", true, {170, 2000, 100, 400, 30, 1500, 900, 100}},
}

// The store-brand name each chain sells under. An item with no brand of its
// own is a *marque de distributeur*, and it is matched across chains on its
// title, which is exactly how a shopper compares them.
mdd_label :: proc(r: Retailer) -> string {
	switch r {
	case .Intermarche:
		return "Pâturages"
	case .Leclerc:
		return "Marque Repère"
	case .Carrefour:
		return "Carrefour"
	case .Kiabi, .Bershka, .Celio, .None:
		return ""
	}
	return ""
}

// ---------------------------------------------------------------------------
// Clothing templates
// ---------------------------------------------------------------------------

Dept :: enum u8 {
	Femme,
	Homme,
	Enfant,
}

C :: struct {
	name:  string,
	dept:  Dept,
	shoes: bool,
	base:  i64, // centimes, before the per-chain jitter
	cat:   string,
}

CLOTHING := [?]C {
	// Femme
	{"T-shirt col rond uni", .Femme, false, 699, "Vêtements > Femme > T-shirts"},
	{"T-shirt manches longues côtelé", .Femme, false, 999, "Vêtements > Femme > T-shirts"},
	{"Chemise en popeline", .Femme, false, 2499, "Vêtements > Femme > Chemises"},
	{"Blouse fluide imprimée", .Femme, false, 1999, "Vêtements > Femme > Chemises"},
	{"Pull col V en maille fine", .Femme, false, 1999, "Vêtements > Femme > Pulls"},
	{"Pull oversize en maille torsadée", .Femme, false, 2999, "Vêtements > Femme > Pulls"},
	{"Gilet boutonné", .Femme, false, 2499, "Vêtements > Femme > Pulls"},
	{"Jean slim taille haute", .Femme, false, 2999, "Vêtements > Femme > Jeans"},
	{"Jean mom délavé", .Femme, false, 3499, "Vêtements > Femme > Jeans"},
	{"Jean flare", .Femme, false, 3999, "Vêtements > Femme > Jeans"},
	{"Pantalon large en lin mélangé", .Femme, false, 2999, "Vêtements > Femme > Pantalons"},
	{"Jupe plissée midi", .Femme, false, 2499, "Vêtements > Femme > Jupes"},
	{"Robe chemise ceinturée", .Femme, false, 3499, "Vêtements > Femme > Robes"},
	{"Robe longue à fleurs", .Femme, false, 3999, "Vêtements > Femme > Robes"},
	{"Veste en jean", .Femme, false, 4499, "Vêtements > Femme > Vestes"},
	{"Trench ceinturé", .Femme, false, 6999, "Vêtements > Femme > Manteaux"},
	{"Doudoune légère à capuche", .Femme, false, 5999, "Vêtements > Femme > Manteaux"},
	{"Sweat à capuche molletonné", .Femme, false, 2499, "Vêtements > Femme > Sweats"},
	{"Legging de sport taille haute", .Femme, false, 1999, "Vêtements > Femme > Sport"},
	{"Baskets basses en toile", .Femme, true, 2999, "Chaussures > Femme > Baskets"},
	{"Bottines à talon carré", .Femme, true, 4999, "Chaussures > Femme > Bottines"},
	{"Ballerines en cuir", .Femme, true, 3999, "Chaussures > Femme > Ballerines"},

	// Homme
	{"T-shirt col rond en coton bio", .Homme, false, 799, "Vêtements > Homme > T-shirts"},
	{"T-shirt rayé manches courtes", .Homme, false, 999, "Vêtements > Homme > T-shirts"},
	{"Polo piqué", .Homme, false, 1999, "Vêtements > Homme > Polos"},
	{"Chemise oxford coupe droite", .Homme, false, 2999, "Vêtements > Homme > Chemises"},
	{"Chemise en flanelle à carreaux", .Homme, false, 3499, "Vêtements > Homme > Chemises"},
	{"Pull col rond en laine mélangée", .Homme, false, 2999, "Vêtements > Homme > Pulls"},
	{"Pull camionneur zippé", .Homme, false, 3499, "Vêtements > Homme > Pulls"},
	{"Sweat à capuche uni", .Homme, false, 2499, "Vêtements > Homme > Sweats"},
	{"Jean slim stretch", .Homme, false, 2999, "Vêtements > Homme > Jeans"},
	{"Jean regular brut", .Homme, false, 3499, "Vêtements > Homme > Jeans"},
	{"Chino coupe ajustée", .Homme, false, 2999, "Vêtements > Homme > Pantalons"},
	{"Pantalon de costume", .Homme, false, 4999, "Vêtements > Homme > Pantalons"},
	{"Veste de costume cintrée", .Homme, false, 8999, "Vêtements > Homme > Vestes"},
	{"Blouson aviateur", .Homme, false, 6999, "Vêtements > Homme > Vestes"},
	{"Parka doublée à capuche", .Homme, false, 7999, "Vêtements > Homme > Manteaux"},
	{"Short en coton", .Homme, false, 1999, "Vêtements > Homme > Shorts"},
	{"Bermuda cargo", .Homme, false, 2499, "Vêtements > Homme > Shorts"},
	{"Baskets running mesh", .Homme, true, 3999, "Chaussures > Homme > Baskets"},
	{"Derbies en cuir", .Homme, true, 5999, "Chaussures > Homme > Derbies"},
	{"Boots cuir doublées", .Homme, true, 6999, "Chaussures > Homme > Boots"},

	// Enfant
	{"T-shirt imprimé enfant", .Enfant, false, 499, "Vêtements > Enfant > T-shirts"},
	{"Sweat à capuche enfant", .Enfant, false, 1299, "Vêtements > Enfant > Sweats"},
	{"Jean slim enfant", .Enfant, false, 1499, "Vêtements > Enfant > Jeans"},
	{"Jogging molletonné enfant", .Enfant, false, 1199, "Vêtements > Enfant > Pantalons"},
	{"Robe à volants fille", .Enfant, false, 1599, "Vêtements > Enfant > Robes"},
	{"Chemise à carreaux garçon", .Enfant, false, 1399, "Vêtements > Enfant > Chemises"},
	{"Doudoune enfant sans manches", .Enfant, false, 2499, "Vêtements > Enfant > Manteaux"},
	{"Pyjama 2 pièces enfant", .Enfant, false, 1299, "Vêtements > Enfant > Pyjamas"},
	{"Baskets scratch enfant", .Enfant, true, 1999, "Chaussures > Enfant > Baskets"},
}

COLORS := [?]string {
	"Noir", "Blanc", "Bleu marine", "Gris chiné", "Rouge", "Vert kaki",
	"Beige", "Bleu ciel", "Rose poudré", "Bordeaux",
}

// Which chains carry which department. Celio is a menswear retailer, Bershka
// sells womenswear and menswear, Kiabi dresses the whole family — so a search
// for a girl's dress finds Kiabi and nobody else, which is how the real market
// looks.
@(private = "file")
carries :: proc(r: Retailer, d: Dept) -> bool {
	switch r {
	case .Kiabi:
		return true
	case .Bershka:
		return d != .Enfant
	case .Celio:
		return d == .Homme
	case .Intermarche, .Leclerc, .Carrefour, .None:
		return false
	}
	return false
}

// Each chain labels its sizes in its own system, which is the whole reason the
// conversion tables exist: Kiabi prints FR, Bershka prints EU, Celio prints
// S/M/L on tops. A shopper who knows they are a 38 has to be able to find the
// Bershka 36.
@(private = "file")
chain_size_system :: proc(r: Retailer, shoes: bool) -> Size_System {
	if shoes {
		return .EU
	}
	switch r {
	case .Kiabi:
		return .FR
	case .Bershka:
		return .EU
	case .Celio:
		return .Alpha
	case .Intermarche, .Leclerc, .Carrefour, .None:
		return .FR
	}
	return .FR
}

@(private = "file")
chart_of :: proc(d: Dept, shoes: bool) -> Size_Chart {
	switch d {
	case .Femme:
		return shoes ? .Women_Shoes : .Women_Tops
	case .Homme:
		return shoes ? .Men_Shoes : .Men_Tops
	case .Enfant:
		return .Kids
	}
	return .None
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

// psych rounds a computed price to one a shop would actually print: to the
// nearest five centimes, and off by one from a round ten so it reads as 3,19
// rather than 3,20 about half the time.
@(private = "file")
psych :: proc(c: i64, r: ^Rng) -> Centimes {
	v := ((c + 2) / 5) * 5
	if v < 10 {
		v = 10
	}
	if v % 10 == 0 && rng_chance(r, 55) {
		v -= 1
	}
	return Centimes(v)
}

@(private = "file")
make_gtin :: proc(serial: i64, allocator := context.allocator) -> string {
	// 3 is the French EAN prefix block. The body is deterministic and the
	// check digit is computed, so every barcode in the fixture validates —
	// which the self-test asserts, because the comparison view groups on it.
	body := fmt.tprintf("3%011d", serial % 100_000_000_000)
	d, ok := ean13_check_digit(body)
	if !ok {
		return strings.clone("", allocator)
	}
	return strings.clone(fmt.tprintf("%s%c", body, rune(d)), allocator)
}

// fill_history walks a price backwards over the snapshots, so the history ends
// at today's price exactly. A tenth of products get a real step change rather
// than a drift, which is what an alert is for.
@(private = "file")
fill_history :: proc(p: ^Product, r: ^Rng) {
	p.history[HISTORY_LEN - 1] = p.price
	v := i64(p.price)
	step_at := -1
	if rng_chance(r, 18) {
		step_at = int(rng_range(r, 1, HISTORY_LEN - 2))
	}
	for i := HISTORY_LEN - 2; i >= 0; i -= 1 {
		if i + 1 == step_at {
			// Walking backwards, a drop today was a higher price before.
			v = v * rng_range(r, 108, 125) / 100
		} else {
			v = v * rng_range(r, 98, 103) / 100
		}
		if v < 10 {
			v = 10
		}
		p.history[i] = Centimes(((v + 2) / 5) * 5)
	}
}

@(private = "file")
nut_known :: proc(n: Nut, class: Food_Class) -> Nutrition {
	if n.kj == 0 && n.sod == 0 {
		return Nutrition{}
	}
	return Nutrition {
		energy_kj = n.kj,
		sugars_mg = n.sug,
		satfat_mg = n.sat,
		total_fat_mg = n.fat,
		sodium_mg = n.sod,
		fibre_mg = n.fib,
		protein_mg = n.pro,
		fruit_pct = n.fru,
		class = class,
		known = true,
	}
}

// fixture_build fills a catalogue. It is the only producer of data in this
// program besides the feed importer, and it goes through the same `finalise`,
// so a generated product and an imported one are indistinguishable downstream.
fixture_build :: proc(c: ^Catalog, seed: u64 = 0x5107) {
	// Rebuilding into a catalogue that already holds products would double
	// everything, so start from empty whatever the caller handed over.
	for &p in c.products {
		product_free(&p)
	}
	clear(&c.products)

	r := rng_make(seed)
	c.generated = true
	delete(c.source)
	c.source = strings.clone("Catalogue de démonstration généré localement")
	for i in 0 ..< HISTORY_LEN {
		delete(c.weeks[i])
		weeks_ago := HISTORY_LEN - 1 - i
		if weeks_ago == 0 {
			c.weeks[i] = strings.clone("auj.")
		} else {
			c.weeks[i] = strings.clone(fmt.tprintf("S-%d", weeks_ago))
		}
	}

	serial: i64 = 1
	grocery := [?]Retailer{.Intermarche, .Leclerc, .Carrefour}

	// The tables are split across two files only so each stays readable.
	shelf := make([dynamic]G, context.temp_allocator)
	for t in GROCERY {
		append(&shelf, t)
	}
	for t in GROCERY2 {
		append(&shelf, t)
	}
	rails := make([dynamic]C, context.temp_allocator)
	for t in CLOTHING {
		append(&rails, t)
	}
	for t in CLOTHING2 {
		append(&rails, t)
	}

	// --- Groceries ---------------------------------------------------------
	for t, ti in shelf {
		variants := strings.split(t.variants, "|", context.temp_allocator)
		for vtext, vi in variants {
			q := parse_quantity(vtext)
			if !q.ok {
				continue
			}
			// The reference price for this size, from the price per kilo,
			// per litre or per piece.
			ref: i64 = q.kind == .Count ? 1_000 : 1_000_000
			base := t.per * q.amount / ref
			// A lot is cheaper per unit — which is exactly what makes the unit
			// price worth computing.
			if q.count > 1 {
				disc := min(q.count, 6) * 3
				base = base * (100 - disc) / 100
			}
			if base < 20 {
				base = 20
			}

			// One barcode for the national brand, shared by every chain that
			// sells it: that is what lets the comparison match on GTIN.
			brand_gtin := make_gtin(serial, context.temp_allocator)
			serial += 1

			for ret in grocery {
				// Not every chain lists every size.
				if vi > 0 && rng_chance(&r, 18) {
					continue
				}
				price := base * rng_range(&r, 92, 112) / 100
				p := Product{}
				p.retailer = ret
				p.id = strings.clone(fmt.tprintf("%s-%04d-%d", retailer_code(ret), ti, vi))
				p.title = strings.clone(fmt.tprintf("%s %s", t.name, vtext))
				p.brand = strings.clone(t.brand)
				p.gtin = strings.clone(brand_gtin)
				p.category = strings.clone(fmt.tprintf("Épicerie > %s", aisle_name(t.aisle)))
				p.aisle = t.aisle
				p.tva = t.tva
				p.qty_text = strings.clone(vtext)
				p.list_price = psych(price, &r)
				p.price = p.list_price
				if rng_chance(&r, 13) {
					p.price = psych(i64(p.list_price) * rng_range(&r, 70, 90) / 100, &r)
				}
				p.avail = rng_chance(&r, 95) ? Availability.In_Stock : Availability.Out_Of_Stock
				p.nutrition = nut_known(t.n, t.class)
				fill_history(&p, &r)
				finalise(&p)
				append(&c.products, p)

				// The store brand, where the chain has one: the same product,
				// no brand of its own, a fifth cheaper, its own barcode. With
				// no brand it is matched across the chains on its title, so
				// three store yoghurts compare against each other.
				if t.own && vi < 2 {
					sp := Product{}
					sp.retailer = ret
					sp.id = strings.clone(fmt.tprintf("%s-MDD-%04d-%d", retailer_code(ret), ti, vi))
					sp.title = strings.clone(fmt.tprintf("%s %s", t.name, vtext))
					sp.brand = strings.clone("")
					sp.gtin = make_gtin(serial)
					serial += 1
					sp.category = strings.clone(fmt.tprintf("Épicerie > %s", aisle_name(t.aisle)))
					sp.aisle = t.aisle
					sp.tva = t.tva
					sp.qty_text = strings.clone(vtext)
					sp.list_price = psych(base * rng_range(&r, 70, 88) / 100, &r)
					sp.price = sp.list_price
					if rng_chance(&r, 8) {
						sp.price = psych(i64(sp.list_price) * rng_range(&r, 78, 92) / 100, &r)
					}
					sp.avail = rng_chance(&r, 97) ? Availability.In_Stock : Availability.Out_Of_Stock
					sp.nutrition = nut_known(t.n, t.class)
					fill_history(&sp, &r)
					finalise(&sp)
					append(&c.products, sp)
				}
			}
		}
	}

	// --- Clothing ----------------------------------------------------------
	clothing := [?]Retailer{.Kiabi, .Bershka, .Celio}
	for t, ti in rails {
		chart := chart_of(t.dept, t.shoes)
		ncolors := int(rng_range(&r, 6, 10))
		for ret in clothing {
			if !carries(ret, t.dept) {
				continue
			}
			sys := chain_size_system(ret, t.shoes)
			// The sizes this chain stocks, written in its own system.
			rows := size_rows(chart)
			sizes := make([dynamic]string)
			for row in rows {
				label := size_cell(row, sys)
				if label == "" {
					continue
				}
				append(&sizes, strings.clone(label))
			}
			// A price position per chain: Bershka above Kiabi, Celio between.
			tilt: i64 = 100
			switch ret {
			case .Kiabi:
				tilt = 78
			case .Bershka:
				tilt = 108
			case .Celio:
				tilt = 96
			case .Intermarche, .Leclerc, .Carrefour, .None:
				tilt = 100
			}
			for ci in 0 ..< ncolors {
				color := COLORS[(ti * 3 + ci) % len(COLORS)]
				p := Product{}
				p.retailer = ret
				p.id = strings.clone(fmt.tprintf("%s-%04d-%02d", retailer_code(ret), ti, ci))
				p.title = strings.clone(t.name)
				p.brand = strings.clone(retailer_name(ret))
				p.gtin = strings.clone("")
				p.category = strings.clone(t.cat)
				p.aisle = .Textile
				p.tva = .Standard
				p.color = strings.clone(color)
				p.chart = chart
				p.size_system = sys
				// Each colour gets its own copy of the size list.
				copy_sizes := make([dynamic]string)
				for s in sizes {
					append(&copy_sizes, strings.clone(s))
				}
				p.sizes = copy_sizes[:]
				p.group = strings.clone(fmt.tprintf("%s-G%04d", retailer_code(ret), ti))
				base := t.base * tilt / 100
				p.list_price = psych(base * rng_range(&r, 94, 108) / 100, &r)
				p.price = p.list_price
				if rng_chance(&r, 22) {
					p.price = psych(i64(p.list_price) * rng_range(&r, 50, 85) / 100, &r)
				}
				p.avail = rng_chance(&r, 92) ? Availability.In_Stock : Availability.Out_Of_Stock
				fill_history(&p, &r)
				finalise(&p)
				append(&c.products, p)
			}
			for s in sizes {
				delete(s)
			}
			delete(sizes)
		}
	}

	catalog_index(c)
}

retailer_code :: proc(r: Retailer) -> string {
	switch r {
	case .Kiabi:
		return "KIA"
	case .Bershka:
		return "BSK"
	case .Celio:
		return "CEL"
	case .Intermarche:
		return "ITM"
	case .Leclerc:
		return "LEC"
	case .Carrefour:
		return "CRF"
	case .None:
		return "XXX"
	}
	return "XXX"
}
