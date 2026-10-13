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

msgid "Palmframe erases the disk you choose and creates two partitions: a 512 MiB EFI system partition and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "Palmframe löscht das gewählte Laufwerk und legt zwei Partitionen an: eine 512 MiB große EFI-Systempartition und ein ext4-Root-Dateisystem auf dem restlichen Platz. Ein Laufwerk mit einem anderen System zu teilen, wird nicht unterstützt."

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
