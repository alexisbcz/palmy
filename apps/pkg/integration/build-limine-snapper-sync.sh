#!/bin/bash
# Builds limine-snapper-sync from its AUR PKGBUILD, inside the Arch Linux ARM
# container, as the unprivileged user (makepkg refuses root). Run by
# arch-container.sh; the package it produces is cached in the state directory
# so later runs install it with pacman -U instead of rebuilding.
#
# ALARM has no `gradle` package, so a Gradle distribution is unpacked and put
# where the PKGBUILD's build() expects it (/usr/bin/gradle), and makepkg runs
# with --nodeps for that one makedepend. Everything else comes from the repos.
set -euo pipefail
GRADLE_VERSION=${GRADLE_VERSION:-9.2.1}
OUT=${1:?usage: build-limine-snapper-sync.sh <out-dir>}
work=$HOME/lss-build
rm -rf "$work"; mkdir -p "$work"; cd "$work"

if [ ! -x /opt/gradle/bin/gradle ]; then
	curl -sSLf -o gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
	sudo rm -rf /opt/gradle-* /opt/gradle
	sudo bsdtar -xf gradle.zip -C /opt
	sudo ln -sfn "/opt/gradle-${GRADLE_VERSION}" /opt/gradle
fi
sudo ln -sf /opt/gradle/bin/gradle /usr/bin/gradle

git clone -q https://aur.archlinux.org/limine-snapper-sync.git aur
cd aur
git log -1 --format='AUR limine-snapper-sync at %h (%cs)'
grep -E '^pkgver=|^pkgrel=' PKGBUILD
makepkg --nodeps --noconfirm --skippgpcheck 2>&1 | tail -20
cp -v ./*.pkg.tar.* "$OUT/"
