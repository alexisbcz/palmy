package ical

// Windows time zone names, which Outlook and Exchange put in TZID, mapped to
// the IANA zone CLDR gives for the "001" territory. Not the whole table: the
// zones a calendar here is likely to meet.
@(private)
WINDOWS_ZONES := [?][2]string {
	{"Dateline Standard Time", "Etc/GMT+12"},
	{"Hawaiian Standard Time", "Pacific/Honolulu"},
	{"Alaskan Standard Time", "America/Anchorage"},
	{"Pacific Standard Time", "America/Los_Angeles"},
	{"US Mountain Standard Time", "America/Phoenix"},
	{"Mountain Standard Time", "America/Denver"},
	{"Central Standard Time", "America/Chicago"},
	{"Central America Standard Time", "America/Guatemala"},
	{"Canada Central Standard Time", "America/Regina"},
	{"Central Standard Time (Mexico)", "America/Mexico_City"},
	{"Eastern Standard Time", "America/New_York"},
	{"SA Pacific Standard Time", "America/Bogota"},
	{"Atlantic Standard Time", "America/Halifax"},
	{"Newfoundland Standard Time", "America/St_Johns"},
	{"E. South America Standard Time", "America/Sao_Paulo"},
	{"Argentina Standard Time", "America/Buenos_Aires"},
	{"UTC", "UTC"},
	{"GMT Standard Time", "Europe/London"},
	{"Greenwich Standard Time", "Atlantic/Reykjavik"},
	{"W. Europe Standard Time", "Europe/Berlin"},
	{"Central Europe Standard Time", "Europe/Budapest"},
	{"Romance Standard Time", "Europe/Paris"},
	{"Central European Standard Time", "Europe/Warsaw"},
	{"W. Central Africa Standard Time", "Africa/Lagos"},
	{"GTB Standard Time", "Europe/Bucharest"},
	{"E. Europe Standard Time", "Europe/Chisinau"},
	{"FLE Standard Time", "Europe/Kiev"},
	{"Israel Standard Time", "Asia/Jerusalem"},
	{"South Africa Standard Time", "Africa/Johannesburg"},
	{"Egypt Standard Time", "Africa/Cairo"},
	{"Turkey Standard Time", "Europe/Istanbul"},
	{"Russian Standard Time", "Europe/Moscow"},
	{"Arab Standard Time", "Asia/Riyadh"},
	{"Arabian Standard Time", "Asia/Dubai"},
	{"Iran Standard Time", "Asia/Tehran"},
	{"Pakistan Standard Time", "Asia/Karachi"},
	{"India Standard Time", "Asia/Calcutta"},
	{"Nepal Standard Time", "Asia/Katmandu"},
	{"Bangladesh Standard Time", "Asia/Dhaka"},
	{"SE Asia Standard Time", "Asia/Bangkok"},
	{"China Standard Time", "Asia/Shanghai"},
	{"Singapore Standard Time", "Asia/Singapore"},
	{"Taipei Standard Time", "Asia/Taipei"},
	{"Tokyo Standard Time", "Asia/Tokyo"},
	{"Korea Standard Time", "Asia/Seoul"},
	{"AUS Central Standard Time", "Australia/Darwin"},
	{"AUS Eastern Standard Time", "Australia/Sydney"},
	{"E. Australia Standard Time", "Australia/Brisbane"},
	{"W. Australia Standard Time", "Australia/Perth"},
	{"New Zealand Standard Time", "Pacific/Auckland"},
}

windows_zone :: proc(name: string) -> (string, bool) {
	for row in WINDOWS_ZONES {
		if row[0] == name {
			return row[1], true
		}
	}
	return "", false
}
