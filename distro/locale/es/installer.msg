# Palmframe installer (apps/installer) — Spanish (Spain), formal (usted).
# Format: distro/locale/README.md. Installed as
# /usr/share/palm/locale/es/installer.msg.
#
# Every msgid in apps/installer must be here; `installer --selftest` checks
# that, and that % verbs and {placeholders} survive translation.
language  = es
name      = Español
english   = Spanish
plural    = n != 1

# --- the frame: rail, heading, buttons -----------------------------------------
msgid "Installer"
msgstr "Instalador"

msgid "Language"
msgstr "Idioma"

msgid "Keyboard"
msgstr "Teclado"

msgid "Time zone"
msgstr "Zona horaria"

msgid "Disk"
msgstr "Disco"

msgid "Account"
msgstr "Cuenta"

msgid "Summary"
msgstr "Resumen"

msgid "Install"
msgstr "Instalar"

msgid "Done"
msgstr "Listo"

msgid "Demo"
msgstr "Demostración"

msgid "Nothing on this computer will be changed."
msgstr "No se modificará nada en este equipo."

msgid "Move"
msgstr "Moverse"

msgid "Next"
msgstr "Siguiente"

msgid "Back"
msgstr "Atrás"

msgid "Step %d of %d"
msgstr "Paso %d de %d"

# --- page headings -------------------------------------------------------------
msgid "Welcome to Palmframe"
msgstr "Bienvenido a Palmframe"

msgid "Choose the language for the installer and for the new system."
msgstr "Elija el idioma del instalador y del nuevo sistema."

msgid "Keyboard layout"
msgstr "Distribución del teclado"

msgid "Choose your keyboard layout. It takes effect at once, so you can try it below."
msgstr "Elija la distribución de su teclado. Se aplica al instante, así que puede probarla abajo."

msgid "Choose the city nearest to you. The clock shows the time there."
msgstr "Elija la ciudad más cercana. El reloj muestra la hora allí."

msgid "Installation disk"
msgstr "Disco de instalación"

msgid "Choose the disk to install Palmframe on."
msgstr "Elija el disco en el que instalar Palmframe."

msgid "Your account"
msgstr "Su cuenta"

msgid "This account can administer the computer."
msgstr "Esta cuenta podrá administrar el equipo."

msgid "Ready to install"
msgstr "Listo para instalar"

msgid "Check your choices. Nothing has been changed yet."
msgstr "Revise sus elecciones. Todavía no se ha modificado nada."

msgid "Installing Palmframe"
msgstr "Instalando Palmframe"

msgid "This takes a few minutes. Every step is in the log."
msgstr "Esto tarda unos minutos. Cada paso queda en el registro."

# --- 1. language ---------------------------------------------------------------
msgid "English"
msgstr "Inglés"

msgid "French"
msgstr "Francés"

msgid "German"
msgstr "Alemán"

msgid "Spanish"
msgstr "Español"

msgid "Arabic"
msgstr "Árabe"

msgid "Japanese"
msgstr "Japonés"

msgid "Not available: no font for this script is installed"
msgstr "No disponible: no hay ninguna fuente instalada para esta escritura"

msgid "This language cannot be shown: no font for its script is installed"
msgstr "No se puede mostrar este idioma: no hay ninguna fuente instalada para su escritura"

# --- 2. keyboard ---------------------------------------------------------------
msgid "Layout"
msgstr "Distribución"

msgid "Search layouts"
msgstr "Buscar distribuciones"

msgid "No layout matches your search."
msgstr "Ninguna distribución coincide con su búsqueda."

msgid "Variant"
msgstr "Variante"

msgid "Default"
msgstr "Predeterminada"

msgid "Try your keyboard"
msgstr "Pruebe su teclado"

msgid "Type here to test the layout"
msgstr "Escriba aquí para probar la distribución"

msgid "Active: %s"
msgstr "Activa: %s"

msgid "No keyboard layouts were found"
msgstr "No se encontró ninguna distribución de teclado"

# --- 3. time zone — the date line is a template: keep the {names}, move them freely ---
msgid "{weekday}, {day} {month} {year}"
msgstr "{weekday}, {day} de {month} de {year}"

msgid "Sunday"
msgstr "domingo"

msgid "Monday"
msgstr "lunes"

msgid "Tuesday"
msgstr "martes"

msgid "Wednesday"
msgstr "miércoles"

msgid "Thursday"
msgstr "jueves"

msgid "Friday"
msgstr "viernes"

msgid "Saturday"
msgstr "sábado"

msgid "January"
msgstr "enero"

msgid "February"
msgstr "febrero"

msgid "March"
msgstr "marzo"

msgid "April"
msgstr "abril"

msgid "May"
msgstr "mayo"

msgid "June"
msgstr "junio"

msgid "July"
msgstr "julio"

msgid "August"
msgstr "agosto"

msgid "September"
msgstr "septiembre"

msgid "October"
msgstr "octubre"

msgid "November"
msgstr "noviembre"

msgid "December"
msgstr "diciembre"

msgid "%s · no time zone data on this system"
msgstr "%s · no hay datos de zonas horarias en este sistema"

msgid "Search for a city, a region or a country"
msgstr "Busque una ciudad, una región o un país"

msgid "No time zone matches your search."
msgstr "Ninguna zona horaria coincide con su búsqueda."

msgid "No time zones were found"
msgstr "No se encontró ninguna zona horaria"

# --- 4. disk — sizes are binary units (GiB = 2^30 bytes) -----------------------
msgid "%.1f TiB"
msgstr "%.1f TiB"

msgid "%.1f GiB"
msgstr "%.1f GiB"

msgid "%d MiB"
msgstr "%d MiB"

msgid "The whole disk will be used"
msgstr "Se usará el disco entero"

msgid "Palmframe erases the disk you choose and creates two partitions: a 512 MiB EFI system partition and an ext4 root file system on the rest. Sharing a disk with another system is not supported."
msgstr "Palmframe borra el disco que elija y crea dos particiones: una partición de sistema EFI de 512 MiB y un sistema de archivos raíz ext4 en el resto. No se admite compartir el disco con otro sistema."

msgid "No disks were found. Attach a disk and restart the installer."
msgstr "No se encontró ningún disco. Conecte uno y reinicie el instalador."

msgid "No disks were found"
msgstr "No se encontró ningún disco"

msgid "Choose a disk"
msgstr "Elija un disco"

msgid "Removable"
msgstr "Extraíble"

msgid "Has partitions"
msgstr "Tiene particiones"

msgid "Its partitions and everything on them will be erased."
msgstr "Se borrarán sus particiones y todo su contenido."

msgid "Unknown model"
msgstr "Modelo desconocido"

msgid "The live system is running from this disk"
msgstr "El sistema en vivo se ejecuta desde este disco"

msgid "This disk is read-only"
msgstr "Este disco es de solo lectura"

msgid "Too small: Palmframe needs at least 4 GiB"
msgstr "Demasiado pequeño: Palmframe necesita al menos 4 GiB"

# --- 4. disk — the erase confirmation ------------------------------------------
msgid "Erase %s?"
msgstr "¿Borrar %s?"

msgid "%s, %s"
msgstr "%s, %s"

msgid "Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."
msgstr "Se eliminará todo lo que contiene este disco: todas las particiones, todos los archivos y cualquier otro sistema operativo. Esta acción no se puede deshacer."

msgid "Cancel"
msgstr "Cancelar"

msgid "Erase %s"
msgstr "Borrar %s"

# --- 5. account ----------------------------------------------------------------
msgid "Full name"
msgstr "Nombre completo"

msgid "Ada Lovelace"
msgstr "Clara Campoamor"

msgid "Optional. Shown on the login screen."
msgstr "Opcional. Se muestra en la pantalla de inicio de sesión."

msgid "User name"
msgstr "Nombre de usuario"

msgid "ada"
msgstr "clara"

msgid "Lowercase letters and digits; used to log in."
msgstr "Letras minúsculas y dígitos; sirve para iniciar sesión."

msgid "Computer name"
msgstr "Nombre del equipo"

msgid "How this computer appears on a network."
msgstr "Cómo aparece este equipo en una red."

msgid "Password"
msgstr "Contraseña"

msgid "Confirm password"
msgstr "Confirme la contraseña"

msgid "Weak password"
msgstr "Contraseña débil"

msgid "Fair password"
msgstr "Contraseña aceptable"

msgid "Strong password"
msgstr "Contraseña segura"

msgid "Use the same password for the administrator (root)"
msgstr "Usar la misma contraseña para el administrador (root)"

msgid "Administrator password"
msgstr "Contraseña del administrador"

msgid "Confirm administrator password"
msgstr "Confirme la contraseña del administrador"

msgid "Some fields need attention"
msgstr "Algunos campos necesitan corrección"

# --- 5. account — what is wrong with a field -----------------------------------
msgid "A name cannot contain a colon or a comma"
msgstr "El nombre no puede contener dos puntos ni comas"

msgid "Choose a user name"
msgstr "Elija un nombre de usuario"

msgid "A user name has at most 32 characters"
msgstr "El nombre de usuario tiene como máximo 32 caracteres"

msgid "A user name starts with a lowercase letter"
msgstr "El nombre de usuario empieza por una letra minúscula"

msgid "Use only lowercase letters, digits, hyphens and underscores"
msgstr "Use solo minúsculas, dígitos, guiones y guiones bajos"

msgid "This name is already used by the system"
msgstr "El sistema ya usa este nombre"

msgid "Choose a name for this computer"
msgstr "Elija un nombre para este equipo"

msgid "A computer name has at most 63 characters"
msgstr "El nombre del equipo tiene como máximo 63 caracteres"

msgid "Use letters, digits and hyphens, without a hyphen at either end"
msgstr "Use letras, dígitos y guiones, sin guion al principio ni al final"

msgid "Choose a password"
msgstr "Elija una contraseña"

msgid "The passwords do not match"
msgstr "Las contraseñas no coinciden"

msgid "Choose a password for the administrator"
msgstr "Elija una contraseña para el administrador"

# --- 6. summary ----------------------------------------------------------------
msgid "%s will be erased"
msgstr "Se borrará %s"

msgid "%s, %s. Everything on it will be lost when you press Install."
msgstr "%s, %s. Todo su contenido se perderá al pulsar Instalar."

msgid "GPT: 512 MiB EFI system partition, ext4 root on the rest"
msgstr "GPT: partición de sistema EFI de 512 MiB, raíz ext4 en el resto"

msgid "The administrator uses the same password"
msgstr "El administrador usa la misma contraseña"

msgid "The administrator has its own password"
msgstr "El administrador tiene su propia contraseña"

msgid "Change"
msgstr "Cambiar"

msgid "The installer refused this plan"
msgstr "El instalador ha rechazado esta configuración"

msgid "The disk has not been confirmed"
msgstr "No se ha confirmado el disco"

# --- 7. install ----------------------------------------------------------------
msgid "Partitioning the disk"
msgstr "Particionando el disco"

msgid "Creating file systems"
msgstr "Creando los sistemas de archivos"

msgid "Mounting"
msgstr "Montando"

msgid "Installing packages"
msgstr "Instalando paquetes"

msgid "Configuring the system"
msgstr "Configurando el sistema"

msgid "Installing the boot loader"
msgstr "Instalando el gestor de arranque"

msgid "Finishing"
msgstr "Finalizando"

msgid "The installation failed"
msgstr "La instalación ha fallado"

msgid "Show details"
msgstr "Mostrar detalles"

msgid "Hide details"
msgstr "Ocultar detalles"

msgid "Back to summary"
msgstr "Volver al resumen"

msgid "Restart"
msgstr "Reiniciar"

# --- 8. done -------------------------------------------------------------------
msgid "Palmframe is installed"
msgstr "Palmframe está instalado"

msgid "Remove the installation medium, then restart the computer to start your new system."
msgstr "Retire el medio de instalación y reinicie el equipo para empezar a usar su nuevo sistema."

msgid "Restart now"
msgstr "Reiniciar ahora"
