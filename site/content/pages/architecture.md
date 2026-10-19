# Architecture

Palmy is modelled on Alpine: a small static busybox userland, a package manager with a world file and signed indexes, and very little else. What is its own is written in Odin: the init, the login daemon, the package manager and its root daemon, and, on the palmy toolkit, the window manager, the greeter, the installer and the applications.

## The boot chain

From firmware to a desktop, as `make distro` builds it. Every box is a process or a stage; the line under each name is what it is or where it lives.

::boot-chain

::include{file="distro/README.md" section="The boot chain" depth=3}

## The pieces

::include{file="distro/README.md" section="The pieces" intro depth=3}

## How a machine is assembled

The order is the contract's. `make -C distro` compiles the Odin binaries, runs `palm build` on every recipe in `distro/recipes` into a repository, and signs its index. Then palm itself installs the `palmy` meta-package into an empty root, under `fakeroot`, and `mkfs.ext4 -d` turns that root into the image's filesystem. The image is assembled the way a user's `palm add` would assemble it, and the installer does the same onto a real partition.

| Stage | Where | Reads | Writes |
| --- | --- | --- | --- |
| Kernel and busybox | `distro/kernel`, `distro/busybox` | upstream sources | `distro/out/bzImage`, `distro/out/busybox` |
| Odin binaries | `distro/{init,login,palm,palmd}`, `apps/*` | the source | `distro/out/bin/` |
| Recipes | `distro/recipes/generate.sh` | `distro/apps`, `distro/base`, the host's glibc and keyboard data | `distro/recipes/*/PALMBUILD` |
| Repository | `palm build`, `palm index` | the recipes | `distro/out/repo/x86_64/`, signed |
| Disk image | `distro/image/build.sh` | the repository | `distro/out/palmy.img` |
| Live ISO | `distro/live/build.sh` | the repository | `distro/out/palmy-live.iso` |

## Where to read further

:::cards
- [palm-init](/distro/palm-init): PID 1, services, device permissions, shutdown.
- [palm-login](/distro/palm-login): the greetd-protocol login daemon and the session loop.
- [palm](/distro/palm): the package manager, its formats and the repository.
- [The contract](/distro/contract): the interfaces every piece was built against.
:::
