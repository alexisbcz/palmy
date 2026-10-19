# Palmframe installer (apps/installer) — French. Typography: the narrow spaces before : ; ? ! are ordinary spaces, because
# not every font the live system might fall back to has U+202F.
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/fr/installer.msg.
#
# Every msgid in apps/installer must be here; `installer --selftest` checks
# that, and that % verbs and {placeholders} survive translation.
language  = fr
name      = Français
english   = French
plural    = n > 1

# --- the frame: rail, heading, buttons -----------------------------------------
msgid "Installer"
msgstr "Installation"

msgid "Language"
msgstr "Langue"

msgid "Keyboard"
msgstr "Clavier"

msgid "Time zone"
msgstr "Fuseau horaire"

msgid "Disk"
msgstr "Disque"

msgid "Account"
msgstr "Compte"

msgid "Summary"
msgstr "Récapitulatif"

msgid "Install"
msgstr "Installer"

msgid "Done"
msgstr "Terminé"

msgid "Demo"
msgstr "Démo"

msgid "Nothing on this computer will be changed."
msgstr "Rien ne sera modifié sur cet ordinateur."

msgid "Move"
msgstr "Se déplacer"

msgid "Next"
msgstr "Suivant"

msgid "Back"
msgstr "Retour"

msgid "Step %d of %d"
msgstr "Étape %d sur %d"

# --- page headings -------------------------------------------------------------
msgid "Welcome to Palmframe"
msgstr "Bienvenue dans Palmframe"

msgid "Choose the language for the installer and for the new system."
msgstr "Choisissez la langue de l’installation et du nouveau système."

msgid "Keyboard layout"
msgstr "Disposition du clavier"

msgid "Choose your keyboard layout. It takes effect at once, so you can try it below."
msgstr "Choisissez la disposition de votre clavier. Elle s’applique immédiatement : vous pouvez l’essayer ci-dessous."

msgid "Choose the city nearest to you. The clock shows the time there."
msgstr "Choisissez la ville la plus proche de chez vous. L’horloge indique l’heure qu’il y est."

msgid "Installation disk"
msgstr "Disque d’installation"

msgid "Choose the disk to install Palmframe on."
msgstr "Choisissez le disque sur lequel installer Palmframe."

msgid "Your account"
msgstr "Votre compte"

msgid "This account can administer the computer."
msgstr "Ce compte pourra administrer l’ordinateur."

msgid "Ready to install"
msgstr "Prêt pour l’installation"

msgid "Check your choices. Nothing has been changed yet."
msgstr "Vérifiez vos choix. Rien n’a encore été modifié."

msgid "Installing Palmframe"
msgstr "Installation de Palmframe"

msgid "This takes a few minutes. Every step is in the log."
msgstr "Cela prend quelques minutes. Chaque étape figure dans le journal."

# --- 1. language ---------------------------------------------------------------
msgid "English"
msgstr "Anglais"

msgid "French"
msgstr "Français"

msgid "German"
msgstr "Allemand"

msgid "Spanish"
msgstr "Espagnol"

msgid "Arabic"
msgstr "Arabe"

msgid "Japanese"
msgstr "Japonais"

msgid "Not available: no font for this script is installed"
msgstr "Indisponible : aucune police n’est installée pour cette écriture"

msgid "This language cannot be shown: no font for its script is installed"
msgstr "Impossible d’afficher cette langue : aucune police n’est installée pour son écriture"

# --- 2. keyboard ---------------------------------------------------------------
msgid "Layout"
msgstr "Disposition"

msgid "Search layouts"
msgstr "Rechercher une disposition"

msgid "No layout matches your search."
msgstr "Aucune disposition ne correspond à votre recherche."

msgid "Variant"
msgstr "Variante"

msgid "Default"
msgstr "Par défaut"

msgid "Try your keyboard"
msgstr "Essayez votre clavier"

msgid "Type here to test the layout"
msgstr "Tapez ici pour tester la disposition"

msgid "Active: %s"
msgstr "Disposition active : %s"

msgid "No keyboard layouts were found"
msgstr "Aucune disposition de clavier n’a été trouvée"

# --- 3. time zone — the date line is a template: keep the {names}, move them freely ---
msgid "{weekday}, {day} {month} {year}"
msgstr "{weekday} {day} {month} {year}"

msgid "Sunday"
msgstr "dimanche"

msgid "Monday"
msgstr "lundi"

msgid "Tuesday"
msgstr "mardi"

msgid "Wednesday"
msgstr "mercredi"

msgid "Thursday"
msgstr "jeudi"

msgid "Friday"
msgstr "vendredi"

msgid "Saturday"
msgstr "samedi"

msgid "January"
msgstr "janvier"

msgid "February"
msgstr "février"

msgid "March"
msgstr "mars"

msgid "April"
msgstr "avril"

msgid "May"
msgstr "mai"

msgid "June"
msgstr "juin"

msgid "July"
msgstr "juillet"

msgid "August"
msgstr "août"

msgid "September"
msgstr "septembre"

msgid "October"
msgstr "octobre"

msgid "November"
msgstr "novembre"

msgid "December"
msgstr "décembre"

msgid "%s · no time zone data on this system"
msgstr "%s · aucune donnée de fuseau horaire sur ce système"

msgid "Search for a city, a region or a country"
msgstr "Rechercher une ville, une région ou un pays"

msgid "No time zone matches your search."
msgstr "Aucun fuseau horaire ne correspond à votre recherche."

msgid "No time zones were found"
msgstr "Aucun fuseau horaire n’a été trouvé"

# --- 4. disk — sizes are binary units (GiB = 2^30 bytes) -----------------------
msgid "%.1f TiB"
msgstr "%.1f Tio"

msgid "%.1f GiB"
msgstr "%.1f Gio"

msgid "%d MiB"
msgstr "%d Mio"

msgid "The whole disk will be used"
msgstr "Le disque entier sera utilisé"

msgid "Palmframe erases the disk you choose and creates a 512 MiB EFI system partition, a small BIOS boot partition so that older computers can start it too, and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "Palmframe efface le disque choisi et y crée une partition système EFI de 512 Mio, une petite partition d'amorçage BIOS pour que les ordinateurs plus anciens puissent aussi le démarrer, et un système de fichiers racine ext4 sur le reste. Le partage d'un disque avec un autre système n'est pas pris en charge."

msgid "No disks were found. Attach a disk and restart the installer."
msgstr "Aucun disque n’a été trouvé. Branchez un disque puis relancez l’installation."

msgid "No disks were found"
msgstr "Aucun disque n’a été trouvé"

msgid "Choose a disk"
msgstr "Choisissez un disque"

msgid "Removable"
msgstr "Amovible"

msgid "Has partitions"
msgstr "Contient des partitions"

msgid "Its partitions and everything on them will be erased."
msgstr "Ses partitions et tout leur contenu seront effacés."

msgid "Unknown model"
msgstr "Modèle inconnu"

msgid "The live system is running from this disk"
msgstr "Le système live fonctionne depuis ce disque"

msgid "This disk is read-only"
msgstr "Ce disque est en lecture seule"

msgid "Too small: Palmframe needs at least 4 GiB"
msgstr "Trop petit : Palmframe a besoin d’au moins 4 Gio"

# --- 4. disk — the erase confirmation ------------------------------------------
msgid "Erase %s?"
msgstr "Effacer %s ?"

msgid "%s, %s"
msgstr "%s, %s"

msgid "Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."
msgstr "Tout le contenu de ce disque sera supprimé : chaque partition, chaque fichier et tout autre système d’exploitation qui s’y trouve. Cette opération est irréversible."

msgid "Cancel"
msgstr "Annuler"

msgid "Erase %s"
msgstr "Effacer %s"

# --- 5. account ----------------------------------------------------------------
msgid "Full name"
msgstr "Nom complet"

msgid "Ada Lovelace"
msgstr "Marie Curie"

msgid "Optional. Shown on the login screen."
msgstr "Facultatif. Affiché sur l’écran de connexion."

msgid "User name"
msgstr "Nom d’utilisateur"

msgid "ada"
msgstr "marie"

msgid "Lowercase letters and digits; used to log in."
msgstr "Lettres minuscules et chiffres ; sert à se connecter."

msgid "Computer name"
msgstr "Nom de l’ordinateur"

msgid "How this computer appears on a network."
msgstr "Le nom sous lequel cet ordinateur apparaît sur un réseau."

msgid "Password"
msgstr "Mot de passe"

msgid "Confirm password"
msgstr "Confirmez le mot de passe"

msgid "Weak password"
msgstr "Mot de passe faible"

msgid "Fair password"
msgstr "Mot de passe moyen"

msgid "Strong password"
msgstr "Mot de passe robuste"

msgid "Use the same password for the administrator (root)"
msgstr "Utiliser le même mot de passe pour l’administrateur (root)"

msgid "Administrator password"
msgstr "Mot de passe administrateur"

msgid "Confirm administrator password"
msgstr "Confirmez le mot de passe administrateur"

msgid "Some fields need attention"
msgstr "Certains champs sont à corriger"

# --- 5. account — what is wrong with a field -----------------------------------
msgid "A name cannot contain a colon or a comma"
msgstr "Le nom ne peut contenir ni deux-points ni virgule"

msgid "Choose a user name"
msgstr "Choisissez un nom d’utilisateur"

msgid "A user name has at most 32 characters"
msgstr "Un nom d’utilisateur compte au plus 32 caractères"

msgid "A user name starts with a lowercase letter"
msgstr "Un nom d’utilisateur commence par une lettre minuscule"

msgid "Use only lowercase letters, digits, hyphens and underscores"
msgstr "N’utilisez que des minuscules, des chiffres, des tirets et des tirets bas"

msgid "This name is already used by the system"
msgstr "Ce nom est déjà utilisé par le système"

msgid "Choose a name for this computer"
msgstr "Choisissez un nom pour cet ordinateur"

msgid "A computer name has at most 63 characters"
msgstr "Un nom d’ordinateur compte au plus 63 caractères"

msgid "Use letters, digits and hyphens, without a hyphen at either end"
msgstr "Utilisez des lettres, des chiffres et des tirets, sans tiret au début ni à la fin"

msgid "Choose a password"
msgstr "Choisissez un mot de passe"

msgid "The passwords do not match"
msgstr "Les mots de passe ne correspondent pas"

msgid "Choose a password for the administrator"
msgstr "Choisissez un mot de passe pour l’administrateur"

# --- 6. summary ----------------------------------------------------------------
msgid "%s will be erased"
msgstr "%s sera effacé"

msgid "%s, %s. Everything on it will be lost when you press Install."
msgstr "%s, %s. Tout son contenu sera perdu dès que vous appuierez sur Installer."

msgid "GPT: 512 MiB EFI system partition, ext4 root on the rest"
msgstr "GPT : partition système EFI de 512 Mio, racine ext4 sur le reste"

msgid "The administrator uses the same password"
msgstr "L’administrateur utilise le même mot de passe"

msgid "The administrator has its own password"
msgstr "L’administrateur a son propre mot de passe"

msgid "Change"
msgstr "Modifier"

msgid "The installer refused this plan"
msgstr "L’installation a refusé ces choix"

msgid "The disk has not been confirmed"
msgstr "Le disque n’a pas été confirmé"

# --- 7. install ----------------------------------------------------------------
msgid "Partitioning the disk"
msgstr "Partitionnement du disque"

msgid "Creating file systems"
msgstr "Création des systèmes de fichiers"

msgid "Mounting"
msgstr "Montage"

msgid "Installing packages"
msgstr "Installation des paquets"

msgid "Configuring the system"
msgstr "Configuration du système"

msgid "Installing the boot loader"
msgstr "Installation du chargeur d’amorçage"

msgid "Finishing"
msgstr "Finalisation"

msgid "The installation failed"
msgstr "L’installation a échoué"

msgid "Show details"
msgstr "Afficher les détails"

msgid "Hide details"
msgstr "Masquer les détails"

msgid "Back to summary"
msgstr "Retour au récapitulatif"

msgid "Restart"
msgstr "Redémarrer"

# --- 8. done -------------------------------------------------------------------
msgid "Palmframe is installed"
msgstr "Palmframe est installé"

msgid "Remove the installation medium, then restart the computer to start your new system."
msgstr "Retirez le support d’installation, puis redémarrez l’ordinateur pour lancer votre nouveau système."

msgid "Restart now"
msgstr "Redémarrer maintenant"

# --- the keyboard page: a layout with no Latin letters -----------------------
msgid "This layout cannot type the Latin letters a user name needs, so English (US) comes with it: Alt+Shift switches between the two."
msgstr "Cette disposition ne peut pas taper les lettres latines qu'exige un nom d'utilisateur ; l'anglais (US) l'accompagne donc : Alt+Maj passe de l'une à l'autre."

# --- the swap file (disk page, summary) -----------------------------------------
msgid "Create a swap file of %s"
msgstr "Créer un fichier d'échange de %s"

msgid "Room on the disk for memory that is not in use, so that a full memory slows the computer down instead of closing programs."
msgstr "De la place sur le disque pour la mémoire inutilisée : une mémoire pleine ralentit alors l'ordinateur au lieu de fermer des programmes."

msgid "Swap"
msgstr "Échange"

msgid "A swap file of %s"
msgstr "Un fichier d'échange de %s"

msgid "None"
msgstr "Aucun"

# --- install_core's messages: validate() problems and progress details --------
# The msgids are MESSAGE_FORMAT in distro/installer/core/message.odin.
msgid "The user name is empty."
msgstr "Le nom d'utilisateur est vide."

msgid "The user name has more than 32 characters."
msgstr "Le nom d'utilisateur dépasse 32 caractères."

msgid "The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'."
msgstr "Le nom d'utilisateur %q doit commencer par une minuscule ou « _ » et ne contenir que a-z, 0-9, « - » et « _ »."

msgid "The user name %q is used by the system."
msgstr "Le nom d'utilisateur %q est réservé au système."

msgid "The full name may not contain ':' or line breaks, and has at most 128 characters."
msgstr "Le nom complet ne peut contenir ni « : » ni saut de ligne, et compte au plus 128 caractères."

msgid "The password is empty."
msgstr "Le mot de passe est vide."

msgid "The password may not contain line breaks."
msgstr "Le mot de passe ne peut pas contenir de saut de ligne."

msgid "The root password may not contain line breaks."
msgstr "Le mot de passe de root ne peut pas contenir de saut de ligne."

msgid "The host name is empty."
msgstr "Le nom de l'ordinateur est vide."

msgid "The host name is longer than 253 characters."
msgstr "Le nom de l'ordinateur dépasse 253 caractères."

msgid "The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'."
msgstr "Le nom d'ordinateur %q n'est pas valide : chaque partie compte de 1 à 63 caractères et ne commence ni ne finit par « - »."

msgid "The host name %q may contain only letters, digits and '-'."
msgstr "Le nom d'ordinateur %q ne peut contenir que des lettres, des chiffres et « - »."

msgid "The language %q is not a locale name like fr_FR."
msgstr "La langue %q n'est pas un nom de paramètres régionaux comme fr_FR."

msgid "The keyboard layout %q is not a valid name."
msgstr "La disposition de clavier %q n'est pas un nom valide."

msgid "The keyboard layout %s has no variant %q."
msgstr "La disposition de clavier %s n'a pas de variante %q."

msgid "There is no keyboard layout %q."
msgstr "Il n'existe pas de disposition de clavier %q."

msgid "The time zone %q is not a zone name like Europe/Paris."
msgstr "Le fuseau horaire %q n'est pas un nom de fuseau comme Europe/Paris."

msgid "There is no time zone %q."
msgstr "Il n'existe pas de fuseau horaire %q."

msgid "The repository %q is neither an http:// URL nor an absolute path."
msgstr "Le dépôt %q n'est ni une URL http:// ni un chemin absolu."

msgid "%q is not a package name."
msgstr "%q n'est pas un nom de paquet."

msgid "The swap size %q is not a size like 2G or 512M."
msgstr "La taille d'échange %q n'est pas une taille comme 2G ou 512M."

msgid "A swap file of %s leaves too little room on %s."
msgstr "Un fichier d'échange de %s laisse trop peu de place sur %s."

msgid "No disk is chosen."
msgstr "Aucun disque n'est choisi."

msgid "%s is a device; a disk image must be a plain file."
msgstr "%s est un périphérique ; une image disque doit être un fichier ordinaire."

msgid "The disk image %s is not a plain file."
msgstr "L'image disque %s n'est pas un fichier ordinaire."

msgid "The disk image %s holds %s; at least 4 GiB is needed."
msgstr "L'image disque %s fait %s ; il faut au moins 4 Gio."

msgid "%s holds the running system; choose another disk."
msgstr "%s contient le système en cours d'exécution ; choisissez un autre disque."

msgid "%s is read-only."
msgstr "%s est en lecture seule."

msgid "%s holds %s; at least 4 GiB is needed."
msgstr "%s fait %s ; il faut au moins 4 Gio."

msgid "%s has a mounted file system; unmount it first."
msgstr "%s a un système de fichiers monté ; démontez-le d'abord."

msgid "There is no disk %s."
msgstr "Il n'y a pas de disque %s."

msgid "Partitioning"
msgstr "Partitionnement"

msgid "Formatting"
msgstr "Formatage"

msgid "Unmounting"
msgstr "Démontage"

msgid "Writing the partition table"
msgstr "Écriture de la table des partitions"

msgid "Waiting for the kernel to see the new partitions"
msgstr "Attente que le noyau voie les nouvelles partitions"

msgid "Formatting the EFI system partition"
msgstr "Formatage de la partition système EFI"

msgid "Formatting the root partition"
msgstr "Formatage de la partition racine"

msgid "Installing %s (%s of %s)"
msgstr "Installation de %s (%s sur %s)"

msgid "Setting the host name"
msgstr "Réglage du nom de l'ordinateur"

msgid "Creating the user account"
msgstr "Création du compte utilisateur"

msgid "Setting language, keyboard and time zone"
msgstr "Réglage de la langue, du clavier et du fuseau horaire"

msgid "Creating a %s swap file"
msgstr "Création d'un fichier d'échange de %s"

msgid "Writing the file system table"
msgstr "Écriture de la table des systèmes de fichiers"

msgid "Copying the boot loader"
msgstr "Copie du chargeur d'amorçage"

msgid "Copying the kernel"
msgstr "Copie du noyau"

msgid "Making the disk start on BIOS computers"
msgstr "Préparation du démarrage sur les ordinateurs BIOS"

msgid "Adding the UEFI boot entry"
msgstr "Ajout de l'entrée de démarrage UEFI"

msgid "UEFI boot entry not written; the disk still boots through the fallback path"
msgstr "Entrée de démarrage UEFI non écrite ; le disque démarre quand même par le chemin de secours"
