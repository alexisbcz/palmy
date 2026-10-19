# The live system's hint on the serial console (and any other login shell).
if [ -t 1 ]; then
	cat <<'HINT'

  This is the Palmy live system. Everything here runs from RAM.

  The graphical installer is on the screen. From this console:
    palm-install                      install from here: it asks each question
    palm-install --help               every option, for unattended installs
    tail -f /var/log/installer.log    the graphical session's output
    poweroff / reboot

HINT
fi
