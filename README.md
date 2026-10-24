# Ubuntu VM Optimizer

A conservative Bash cleanup script for small Ubuntu Server VMs (including 1-vCPU / 2-GB RAM instances). It applies the headless-server changes tested on a VM:

- Sets the default systemd target to `multi-user.target`.
- Disables Apport crash reporting.
- Disables the `motd-news.timer` when available.
- Cleans the APT cache and offers to remove unused packages.
- Reports memory, root filesystem usage, default target, and failed systemd units.

Optional flags can remove Snap or packages that are often unnecessary on headless VMs. These removals are **not enabled by default** because they may break a workload that depends on them.

## Requirements

- Ubuntu Linux (the script refuses to run on other distributions)
- Bash and systemd
- Root privileges (`sudo`)
- Network access is not required by the script itself

## Quick install (one copy-paste)

Run on the Ubuntu VM:

```bash
git clone https://github.com/GodYtteria/ubuntu-vm-optimizer.git && cd ubuntu-vm-optimizer && sudo ./optimize-ubuntu-server.sh --dry-run && sudo ./optimize-ubuntu-server.sh
```

The first run is a dry run that only prints the plan. The second run applies it and asks for confirmation.

No `git` on the VM? `sudo apt-get install -y git` first.

## Usage

Review the script before running it. The sections below cover the flags.

Optional package cleanup (read the APT plan and confirm carefully):

```bash
sudo ./optimize-ubuntu-server.sh --remove-optional-packages
```

Snap removal (removes all installed Snap apps; review `snap list` first):

```bash
sudo ./optimize-ubuntu-server.sh --remove-snap
```

The `--yes` option skips the main confirmation and APT autoremove confirmation, but deliberately does **not** approve optional package or Snap removals. Avoid unattended execution on production systems.

## Important safety notes

- Make a VM snapshot/backup before making changes to production servers.
- Do not remove `multipath-tools` if the VM uses multipath storage, or `open-iscsi` if it relies on iSCSI.
- Do not remove Snap if any required service is installed as a Snap package.
- The script does not install Docker, change CPU/RAM allocation, tune application settings, or promise a specific performance gain.
- `multi-user.target` changes the default boot target but does not uninstall desktop packages.
- `apt autoremove --purge` is reviewed before confirmation; inspect the package list carefully.

## License

MIT. Copyright (c) GodYtteria. See [LICENSE](LICENSE).
