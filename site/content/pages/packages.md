# Package list

The repository `make distro` builds has **{{packageCount}} packages**. The `palmy` meta-package depends on {{palmyCount}} of them, and installing it is how both the disk image and the installer put a system together. The others are there for `palm add` to fetch, or for the live system: the installer and the tools it runs.

:::callout{type=info title="Read from distro/recipes"}
Generated from each recipe's `PALMBUILD`. Most recipes are themselves written by `distro/recipes/generate.sh` from what they package; a few are written by hand. The recipe format is specified in `distro/palm/PALMBUILD.md`.
:::

::package-table
