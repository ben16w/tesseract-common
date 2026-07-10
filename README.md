# common

Shared tooling, scripts, and Docker Compose files for the Tesseract infrastructure.

## Contents

- `compose/` — Docker Compose files for all services.
- `scripts/` — Bash scripts used by Ansible roles and manual operations.
- `Justfile` — Shared Justfile for development and CI across all repositories.
- `setup.sh` — Downloads the latest Justfile and self-updates from this repository.

## Usage

### Syncing the Justfile to another repo

Run directly from any repository:

```sh
curl -sSL https://raw.githubusercontent.com/ben16w/common/main/setup.sh | bash
```

This downloads the latest `Justfile` into the current directory.

### Linting

```sh
just install-venv
just lint
```

## License

This project is licensed under the Unlicense. See the [LICENSE](LICENSE) file for details.
