# Palmframe installer (apps/installer) — German, formal (Sie), as installers are.
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/de/installer.msg.
#
# Every msgid in apps/installer must be here; `installer --selftest` checks
# that, and that % verbs and {placeholders} survive translation.
language  = de
name      = Deutsch
english   = German
plural    = n != 1

# --- the frame: rail, heading, buttons -----------------------------------------
msgid "Installer"
msgstr "Installationsprogramm"

msgid "Language"
msgstr "Sprache"

msgid "Keyboard"
msgstr "Tastatur"

msgid "Time zone"
msgstr "Zeitzone"

msgid "Disk"
msgstr "Laufwerk"

msgid "Account"
msgstr "Konto"

msgid "Summary"
msgstr "Übersicht"

msgid "Install"
msgstr "Installieren"

msgid "Done"
msgstr "Fertig"

msgid "Demo"
msgstr "Demo"

msgid "Nothing on this computer will be changed."
msgstr "An diesem Rechner wird nichts verändert."

msgid "Move"
msgstr "Wechseln"

msgid "Next"
msgstr "Weiter"

msgid "Back"
msgstr "Zurück"

msgid "Step %d of %d"
msgstr "Schritt %d von %d"

# --- page headings -------------------------------------------------------------
msgid "Welcome to Palmframe"
msgstr "Willkommen bei Palmframe"

msgid "Choose the language for the installer and for the new system."
msgstr "Wählen Sie die Sprache für das Installationsprogramm und das neue System."

msgid "Keyboard layout"
msgstr "Tastaturbelegung"

msgid "Choose your keyboard layout. It takes effect at once, so you can try it below."
msgstr "Wählen Sie Ihre Tastaturbelegung. Sie gilt sofort, Sie können sie unten ausprobieren."

msgid "Choose the city nearest to you. The clock shows the time there."
msgstr "Wählen Sie die nächstgelegene Stadt. Die Uhr zeigt die dortige Zeit."

msgid "Installation disk"
msgstr "Installationslaufwerk"

msgid "Choose the disk to install Palmframe on."
msgstr "Wählen Sie das Laufwerk, auf dem Palmframe installiert werden soll."

msgid "Your account"
msgstr "Ihr Konto"

msgid "This account can administer the computer."
msgstr "Dieses Konto kann den Rechner verwalten."

msgid "Ready to install"
msgstr "Bereit zur Installation"

msgid "Check your choices. Nothing has been changed yet."
msgstr "Prüfen Sie Ihre Auswahl. Bisher wurde nichts verändert."

msgid "Installing Palmframe"
msgstr "Palmframe wird installiert"

msgid "This takes a few minutes. Every step is in the log."
msgstr "Das dauert einige Minuten. Jeder Schritt steht im Protokoll."

# --- 1. language ---------------------------------------------------------------
msgid "English"
msgstr "Englisch"

msgid "French"
msgstr "Französisch"

msgid "German"
msgstr "Deutsch"

msgid "Spanish"
msgstr "Spanisch"

msgid "Arabic"
msgstr "Arabisch"

msgid "Japanese"
msgstr "Japanisch"

msgid "Not available: no font for this script is installed"
msgstr "Nicht verfügbar: Für diese Schrift ist keine Schriftart installiert"

msgid "This language cannot be shown: no font for its script is installed"
msgstr "Diese Sprache kann nicht angezeigt werden: Für ihre Schrift ist keine Schriftart installiert"

# --- 2. keyboard ---------------------------------------------------------------
msgid "Layout"
msgstr "Belegung"

msgid "Search layouts"
msgstr "Belegungen durchsuchen"

msgid "No layout matches your search."
msgstr "Keine Belegung passt zu Ihrer Suche."

msgid "Variant"
msgstr "Variante"

msgid "Default"
msgstr "Standard"

msgid "Try your keyboard"
msgstr "Tastatur ausprobieren"

msgid "Type here to test the layout"
msgstr "Hier tippen, um die Belegung zu testen"

msgid "Active: %s"
msgstr "Aktiv: %s"

msgid "No keyboard layouts were found"
msgstr "Keine Tastaturbelegungen gefunden"

# --- 3. time zone — the date line is a template: keep the {names}, move them freely ---
msgid "{weekday}, {day} {month} {year}"
msgstr "{weekday}, {day}. {month} {year}"

msgid "Sunday"
msgstr "Sonntag"

msgid "Monday"
msgstr "Montag"

msgid "Tuesday"
msgstr "Dienstag"

msgid "Wednesday"
msgstr "Mittwoch"

msgid "Thursday"
msgstr "Donnerstag"

msgid "Friday"
msgstr "Freitag"

msgid "Saturday"
msgstr "Samstag"

msgid "January"
msgstr "Januar"

msgid "February"
msgstr "Februar"

msgid "March"
msgstr "März"

msgid "April"
msgstr "April"

msgid "May"
msgstr "Mai"

msgid "June"
msgstr "Juni"

msgid "July"
msgstr "Juli"

msgid "August"
msgstr "August"

msgid "September"
msgstr "September"

msgid "October"
msgstr "Oktober"

msgid "November"
msgstr "November"

msgid "December"
msgstr "Dezember"

msgid "%s · no time zone data on this system"
msgstr "%s · keine Zeitzonendaten auf diesem System"

msgid "Search for a city, a region or a country"
msgstr "Nach Stadt, Region oder Land suchen"

msgid "No time zone matches your search."
msgstr "Keine Zeitzone passt zu Ihrer Suche."

msgid "No time zones were found"
msgstr "Keine Zeitzonen gefunden"

# --- 4. disk — sizes are binary units (GiB = 2^30 bytes) -----------------------
msgid "%.1f TiB"
msgstr "%.1f TiB"

msgid "%.1f GiB"
msgstr "%.1f GiB"

msgid "%d MiB"
msgstr "%d MiB"

msgid "The whole disk will be used"
msgstr "Das gesamte Laufwerk wird verwendet"

msgid "Palmframe erases the disk you choose and creates a 512 MiB EFI system partition, a small BIOS boot partition so that older computers can start it too, and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "Palmframe löscht die gewählte Festplatte und legt eine 512 MiB große EFI-Systempartition an, eine kleine BIOS-Boot-Partition, damit auch ältere Computer davon starten können, und auf dem Rest ein ext4-Wurzeldateisystem. Eine Festplatte mit einem anderen System zu teilen, wird nicht unterstützt."

msgid "No disks were found. Attach a disk and restart the installer."
msgstr "Keine Laufwerke gefunden. Schließen Sie ein Laufwerk an und starten Sie das Installationsprogramm neu."

msgid "No disks were found"
msgstr "Keine Laufwerke gefunden"

msgid "Choose a disk"
msgstr "Wählen Sie ein Laufwerk"

msgid "Removable"
msgstr "Wechselmedium"

msgid "Has partitions"
msgstr "Partitioniert"

msgid "Its partitions and everything on them will be erased."
msgstr "Seine Partitionen und alles darauf werden gelöscht."

msgid "Unknown model"
msgstr "Unbekanntes Modell"

msgid "The live system is running from this disk"
msgstr "Das Live-System läuft von diesem Laufwerk"

msgid "This disk is read-only"
msgstr "Dieses Laufwerk ist schreibgeschützt"

msgid "Too small: Palmframe needs at least 4 GiB"
msgstr "Zu klein: Palmframe benötigt mindestens 4 GiB"

# --- 4. disk — the erase confirmation ------------------------------------------
msgid "Erase %s?"
msgstr "%s löschen?"

msgid "%s, %s"
msgstr "%s, %s"

msgid "Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."
msgstr "Alles auf diesem Laufwerk wird gelöscht: jede Partition, jede Datei und jedes andere Betriebssystem darauf. Das lässt sich nicht rückgängig machen."

msgid "Cancel"
msgstr "Abbrechen"

msgid "Erase %s"
msgstr "%s löschen"

# --- 5. account ----------------------------------------------------------------
msgid "Full name"
msgstr "Vollständiger Name"

msgid "Ada Lovelace"
msgstr "Erika Mustermann"

msgid "Optional. Shown on the login screen."
msgstr "Optional. Wird auf dem Anmeldebildschirm angezeigt."

msgid "User name"
msgstr "Benutzername"

msgid "ada"
msgstr "erika"

msgid "Lowercase letters and digits; used to log in."
msgstr "Kleinbuchstaben und Ziffern; zum Anmelden."

msgid "Computer name"
msgstr "Rechnername"

msgid "How this computer appears on a network."
msgstr "So erscheint dieser Rechner im Netzwerk."

msgid "Password"
msgstr "Passwort"

msgid "Confirm password"
msgstr "Passwort bestätigen"

msgid "Weak password"
msgstr "Schwaches Passwort"

msgid "Fair password"
msgstr "Mittelstarkes Passwort"

msgid "Strong password"
msgstr "Starkes Passwort"

msgid "Use the same password for the administrator (root)"
msgstr "Dasselbe Passwort für den Administrator (root) verwenden"

msgid "Administrator password"
msgstr "Administratorpasswort"

msgid "Confirm administrator password"
msgstr "Administratorpasswort bestätigen"

msgid "Some fields need attention"
msgstr "Einige Felder müssen korrigiert werden"

# --- 5. account — what is wrong with a field -----------------------------------
msgid "A name cannot contain a colon or a comma"
msgstr "Der Name darf weder Doppelpunkt noch Komma enthalten"

msgid "Choose a user name"
msgstr "Wählen Sie einen Benutzernamen"

msgid "A user name has at most 32 characters"
msgstr "Ein Benutzername hat höchstens 32 Zeichen"

msgid "A user name starts with a lowercase letter"
msgstr "Ein Benutzername beginnt mit einem Kleinbuchstaben"

msgid "Use only lowercase letters, digits, hyphens and underscores"
msgstr "Nur Kleinbuchstaben, Ziffern, Binde- und Unterstriche"

msgid "This name is already used by the system"
msgstr "Dieser Name wird bereits vom System verwendet"

msgid "Choose a name for this computer"
msgstr "Wählen Sie einen Namen für diesen Rechner"

msgid "A computer name has at most 63 characters"
msgstr "Ein Rechnername hat höchstens 63 Zeichen"

msgid "Use letters, digits and hyphens, without a hyphen at either end"
msgstr "Buchstaben, Ziffern und Bindestriche, ohne Bindestrich am Anfang oder Ende"

msgid "Choose a password"
msgstr "Wählen Sie ein Passwort"

msgid "The passwords do not match"
msgstr "Die Passwörter stimmen nicht überein"

msgid "Choose a password for the administrator"
msgstr "Wählen Sie ein Passwort für den Administrator"

# --- 6. summary ----------------------------------------------------------------
msgid "%s will be erased"
msgstr "%s wird gelöscht"

msgid "%s, %s. Everything on it will be lost when you press Install."
msgstr "%s, %s. Alle Daten darauf gehen verloren, sobald Sie „Installieren“ wählen."

msgid "GPT: 512 MiB EFI system partition, ext4 root on the rest"
msgstr "GPT: 512 MiB EFI-Systempartition, ext4-Root auf dem Rest"

msgid "The administrator uses the same password"
msgstr "Der Administrator verwendet dasselbe Passwort"

msgid "The administrator has its own password"
msgstr "Der Administrator hat ein eigenes Passwort"

msgid "Change"
msgstr "Ändern"

msgid "The installer refused this plan"
msgstr "Das Installationsprogramm hat diese Auswahl abgelehnt"

msgid "The disk has not been confirmed"
msgstr "Das Laufwerk wurde nicht bestätigt"

# --- 7. install ----------------------------------------------------------------
msgid "Partitioning the disk"
msgstr "Laufwerk wird partitioniert"

msgid "Creating file systems"
msgstr "Dateisysteme werden angelegt"

msgid "Mounting"
msgstr "Einhängen"

msgid "Installing packages"
msgstr "Pakete werden installiert"

msgid "Configuring the system"
msgstr "System wird eingerichtet"

msgid "Installing the boot loader"
msgstr "Bootloader wird installiert"

msgid "Finishing"
msgstr "Abschluss"

msgid "The installation failed"
msgstr "Die Installation ist fehlgeschlagen"

msgid "Show details"
msgstr "Details anzeigen"

msgid "Hide details"
msgstr "Details ausblenden"

msgid "Back to summary"
msgstr "Zurück zur Übersicht"

msgid "Restart"
msgstr "Neu starten"

# --- 8. done -------------------------------------------------------------------
msgid "Palmframe is installed"
msgstr "Palmframe ist installiert"

msgid "Remove the installation medium, then restart the computer to start your new system."
msgstr "Entfernen Sie das Installationsmedium und starten Sie den Rechner neu, um Ihr neues System zu verwenden."

msgid "Restart now"
msgstr "Jetzt neu starten"

# --- the swap file (disk page, summary) -----------------------------------------
msgid "Create a swap file of %s"
msgstr "Eine Auslagerungsdatei von %s anlegen"

msgid "Room on the disk for memory that is not in use, so that a full memory slows the computer down instead of closing programs."
msgstr "Platz auf der Festplatte für Speicher, der gerade nicht gebraucht wird: Ist der Arbeitsspeicher voll, wird der Computer langsamer, statt Programme zu beenden."

msgid "Swap"
msgstr "Auslagerung"

msgid "A swap file of %s"
msgstr "Eine Auslagerungsdatei von %s"

msgid "None"
msgstr "Keine"

# --- install_core's messages: validate() problems and progress details --------
# The msgids are MESSAGE_FORMAT in distro/installer/core/message.odin.
msgid "The user name is empty."
msgstr "Der Benutzername ist leer."

msgid "The user name has more than 32 characters."
msgstr "Der Benutzername hat mehr als 32 Zeichen."

msgid "The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'."
msgstr "Der Benutzername %q muss mit einem Kleinbuchstaben oder „_“ beginnen und darf nur a-z, 0-9, „-“ und „_“ enthalten."

msgid "The user name %q is used by the system."
msgstr "Der Benutzername %q wird vom System verwendet."

msgid "The full name may not contain ':' or line breaks, and has at most 128 characters."
msgstr "Der vollständige Name darf weder „:“ noch Zeilenumbrüche enthalten und hat höchstens 128 Zeichen."

msgid "The password is empty."
msgstr "Das Passwort ist leer."

msgid "The password may not contain line breaks."
msgstr "Das Passwort darf keine Zeilenumbrüche enthalten."

msgid "The root password may not contain line breaks."
msgstr "Das root-Passwort darf keine Zeilenumbrüche enthalten."

msgid "The host name is empty."
msgstr "Der Rechnername ist leer."

msgid "The host name is longer than 253 characters."
msgstr "Der Rechnername ist länger als 253 Zeichen."

msgid "The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'."
msgstr "Der Rechnername %q ist ungültig: Jeder Teil hat 1 bis 63 Zeichen und beginnt und endet nicht mit „-“."

msgid "The host name %q may contain only letters, digits and '-'."
msgstr "Der Rechnername %q darf nur Buchstaben, Ziffern und „-“ enthalten."

msgid "The language %q is not a locale name like fr_FR."
msgstr "Die Sprache %q ist kein Gebietsschema-Name wie fr_FR."

msgid "The keyboard layout %q is not a valid name."
msgstr "Die Tastaturbelegung %q ist kein gültiger Name."

msgid "The keyboard layout %s has no variant %q."
msgstr "Die Tastaturbelegung %s hat keine Variante %q."

msgid "There is no keyboard layout %q."
msgstr "Es gibt keine Tastaturbelegung %q."

msgid "The time zone %q is not a zone name like Europe/Paris."
msgstr "Die Zeitzone %q ist kein Zonenname wie Europe/Paris."

msgid "There is no time zone %q."
msgstr "Es gibt keine Zeitzone %q."

msgid "The repository %q is neither an http:// URL nor an absolute path."
msgstr "Die Paketquelle %q ist weder eine http://-URL noch ein absoluter Pfad."

msgid "%q is not a package name."
msgstr "%q ist kein Paketname."

msgid "The swap size %q is not a size like 2G or 512M."
msgstr "Die Auslagerungsgröße %q ist keine Größe wie 2G oder 512M."

msgid "A swap file of %s leaves too little room on %s."
msgstr "Eine Auslagerungsdatei von %s lässt auf %s zu wenig Platz."

msgid "No disk is chosen."
msgstr "Es ist keine Festplatte gewählt."

msgid "%s is a device; a disk image must be a plain file."
msgstr "%s ist ein Gerät; ein Festplattenabbild muss eine gewöhnliche Datei sein."

msgid "The disk image %s is not a plain file."
msgstr "Das Festplattenabbild %s ist keine gewöhnliche Datei."

msgid "The disk image %s holds %s; at least 4 GiB is needed."
msgstr "Das Festplattenabbild %s fasst %s; mindestens 4 GiB werden benötigt."

msgid "%s holds the running system; choose another disk."
msgstr "Auf %s läuft das aktuelle System; wählen Sie eine andere Festplatte."

msgid "%s is read-only."
msgstr "%s ist schreibgeschützt."

msgid "%s holds %s; at least 4 GiB is needed."
msgstr "%s fasst %s; mindestens 4 GiB werden benötigt."

msgid "%s has a mounted file system; unmount it first."
msgstr "Auf %s ist ein Dateisystem eingehängt; hängen Sie es zuerst aus."

msgid "There is no disk %s."
msgstr "Es gibt keine Festplatte %s."

msgid "Partitioning"
msgstr "Partitionierung"

msgid "Formatting"
msgstr "Formatierung"

msgid "Unmounting"
msgstr "Aushängen"

msgid "Writing the partition table"
msgstr "Partitionstabelle wird geschrieben"

msgid "Waiting for the kernel to see the new partitions"
msgstr "Warten, bis der Kernel die neuen Partitionen sieht"

msgid "Formatting the EFI system partition"
msgstr "EFI-Systempartition wird formatiert"

msgid "Formatting the root partition"
msgstr "Wurzelpartition wird formatiert"

msgid "Installing %s (%s of %s)"
msgstr "%s wird installiert (%s von %s)"

msgid "Setting the host name"
msgstr "Rechnername wird gesetzt"

msgid "Creating the user account"
msgstr "Benutzerkonto wird angelegt"

msgid "Setting language, keyboard and time zone"
msgstr "Sprache, Tastatur und Zeitzone werden eingestellt"

msgid "Creating a %s swap file"
msgstr "Auslagerungsdatei von %s wird angelegt"

msgid "Writing the file system table"
msgstr "Dateisystemtabelle wird geschrieben"

msgid "Copying the boot loader"
msgstr "Bootloader wird kopiert"

msgid "Copying the kernel"
msgstr "Kernel wird kopiert"

msgid "Making the disk start on BIOS computers"
msgstr "Festplatte wird für BIOS-Computer startfähig gemacht"

msgid "Adding the UEFI boot entry"
msgstr "UEFI-Starteintrag wird hinzugefügt"

msgid "UEFI boot entry not written; the disk still boots through the fallback path"
msgstr "UEFI-Starteintrag nicht geschrieben; die Festplatte startet dennoch über den Ausweichpfad"
