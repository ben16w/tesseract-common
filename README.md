# common

Shared Docker Compose definitions, maintenance scripts, and repository tooling for the Tesseract infrastructure.

## What this repository contains

- `compose/` — service-specific Docker Compose files such as Gitea, Forgejo, Jellyfin, OpenHands, Paperless, and many more.
- `scripts/` — operational shell scripts for backups, storage provisioning, and other host-level maintenance tasks.
- `Justfile` — a shared task runner used across Tesseract repositories for setup, linting, and maintenance workflows.
- `setup.sh` — bootstrap script that installs prerequisites, refreshes itself, and downloads the latest shared `Justfile`.

## Quick start

### Clone this repository

```sh
git clone https://git.tepig.welney.net/tesseract/common.git
cd common
```

### Download the shared `Justfile` into another repository

If you want to reuse the shared `Justfile` elsewhere without cloning this whole repository:

```sh
curl -fsSLO https://git.tepig.welney.net/tesseract/common/raw/branch/main/setup.sh
sh ./setup.sh
```

This installs the required local tooling when needed and writes the latest `Justfile` into the current directory.

### Set up the linting environment

```sh
just install-venv
```

This creates `.venv/` and installs the Python-based lint dependencies from `requirements.txt`.

## Common workflows

### Run all linters

```sh
just lint
```

This runs the shared lint suite, including:

- YAML linting
- shell script linting
- Docker Compose validation
- Python linting
- Ansible linting when Ansible content is present

### Inspect available tasks

```sh
just --list
```

### Refresh repository dependencies

```sh
just install
```

This installs the Python virtual environment and, when a `requirements.yml` file exists, Ansible Galaxy collections.

## Repository layout

### `compose/`

The `compose/` directory contains standalone Compose files for individual services. Pick the files relevant to the stack you want to deploy, for example:

- `compose/docker-compose.gitea.yml`
- `compose/docker-compose.forgejo.yml`
- `compose/docker-compose.openhands.yml`
- `compose/docker-compose.paperless.yml`
- `compose/docker-compose.jellyfin.yml`

### `scripts/`

The `scripts/` directory contains host-side operational helpers, including:

- `scripts/kopia_backup.sh` — Kopia backup workflow
- `scripts/local_backup.sh` — rotating local backups
- `scripts/mirror_backup.sh` — rsync mirror backups
- `scripts/provision_volume.sh` — encrypted volume provisioning
- `scripts/rsync_backup.sh` — incremental rsync backups

These scripts are intended for operators who are comfortable reviewing and running infrastructure automation on their own systems.

## License

This project is licensed under the Unlicense. See [LICENSE](LICENSE) for details.
