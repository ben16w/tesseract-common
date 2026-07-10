# Justfile for Tesseract repositories.
#
# This file is shared across all Tesseract repos. It provides a common set of
# recipes for setup, linting, testing, and deployment tasks.

# ── variables ───────────────────────────────────────────────────────────────────

venv := ".venv"

cyan := '\033[0;36m'
green := '\033[0;32m'
red := '\033[0;31m'
yellow := '\033[0;33m'
reset := '\033[0m'

info := cyan + "→" + reset
ok := green + "✔" + reset
err := red + "✗" + reset
skip := yellow + "~" + reset

# ── helpers ────────────────────────────────────────────────────────────

[no-exit-message]
_venv:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{venv}}/bin/activate" ]; then
        echo -e "{{err}} No virtual environment found. Run 'just install-venv' first." >&2
        exit 1
    fi

[no-exit-message]
_docker:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v docker > /dev/null 2>&1; then
        echo -e "{{err}} Docker is not installed. Install it from: https://docs.docker.com/engine/install/" >&2
        exit 1
    fi

[no-exit-message]
_docker-access:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! docker info > /dev/null 2>&1; then
        echo -e "{{err}} Docker is not accessible. Ensure Docker is running and the current user has socket access." >&2
        exit 1
    fi

[no-exit-message]
_non-root:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(id -u)" -eq 0 ] && [ "${CI:-}" != "true" ]; then
        echo -e "{{err}} Do not run recipe as root." >&2
        exit 1
    fi

[no-exit-message]
_require path:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e "{{path}}" ]; then
        echo -e "{{err}} Not found: {{path}}" >&2
        exit 1
    fi

[no-exit-message]
_python3:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v python3 > /dev/null 2>&1; then
        echo -e "{{err}} python3 is not installed. Install it with: apt install python3" >&2
        exit 1
    fi
    if ! python3 -m pip --version > /dev/null 2>&1; then
        echo -e "{{err}} python3-pip is not installed. Install it with: apt install python3-pip" >&2
        exit 1
    fi
    if ! python3 -m venv --help > /dev/null 2>&1; then
        echo -e "{{err}} python3-venv is not installed. Install it with: apt install python3-venv" >&2
        exit 1
    fi

# ── help ───────────────────────────────────────────────────────────────────────

# List available recipes
help:
    @just --list

# ── lint ───────────────────────────────────────────────────────────────────────

# Run all linters in sequence
[group('lint')]
lint: lint-yaml lint-shell lint-docker lint-ansible lint-python

# Lint YAML files with yamllint
[group('lint')]
lint-yaml: _venv
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Linting YAML files..."
    find . -type f \
        \( -name "*.yml" -o -name "*.yaml" \) \
        ! -path "./.venv/*" \
        ! -path "./.ansible/*" \
        ! -path "./ansible_collections/*" \
        -exec {{venv}}/bin/yamllint -d '{extends: relaxed, rules: {line-length: disable}}' {} +
    echo -e "{{ok}} YAML lint passed."

# Lint shell scripts with shellcheck
[group('lint')]
lint-shell: _venv
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Linting shell scripts..."
    find . -type f -name '*.sh' \
        ! -path "./.venv/*" \
        ! -path "./.ansible/*" \
        ! -path "./ansible_collections/*" \
        -exec {{venv}}/bin/shellcheck -S warning {} +
    echo -e "{{ok}} Shell lint passed."

# Validate Docker Compose files
[group('lint')]
lint-docker: _venv
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Linting Docker Compose files..."
    find . -type f -name 'docker-compose.*.yml' \
        ! -path "./.venv/*" \
        ! -path "./.ansible/*" \
        ! -path "./ansible_collections/*" \
        -exec {{venv}}/bin/compose-lint {} +
    echo -e "{{ok}} Docker lint passed."

# Lint Python files with flake8
[group('lint')]
lint-python: _venv
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Linting Python files..."
    find . -type f -name '*.py' \
        ! -path "./.venv/*" \
        ! -path "./.ansible/*" \
        ! -path "./ansible_collections/*" \
        -exec {{venv}}/bin/flake8 --max-line-length=120 {} +
    echo -e "{{ok}} Python lint passed."

# Lint Ansible files with ansible-lint
[group('lint')]
lint-ansible: _venv
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Linting Ansible files..."
    if [[ -f "ansible.cfg" || -d "roles" || -d "playbooks" || -d "group_vars" || -d "host_vars" ]]; then
        PATH="$(realpath "{{venv}}")/bin:${PATH}" \
        ANSIBLE_ASK_VAULT_PASS=false \
        {{venv}}/bin/ansible-lint \
            --exclude "ansible_collections/" "playbooks/" "docker-compose.*.yml" "vars.yml" \
            -x var-naming[no-role-prefix] \
            -x galaxy[no-changelog] \
            --offline -q
    fi
    echo -e "{{ok}} Ansible lint passed."

# ── setup ──────────────────────────────────────────────────────────────────────

# Install virtual environment and Galaxy collections
[group('setup')]
install: install-venv install-galaxy

# Install Ansible Galaxy collections from requirements.yml
[group('setup')]
install-galaxy: _venv _non-root
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Installing Ansible Galaxy collections..."
    if [ ! -f requirements.yml ]; then
        echo -e "{{skip}} No requirements.yml file found."
        exit 0
    fi
    if OUTPUT=$({{venv}}/bin/ansible-galaxy collection install -r requirements.yml 2>&1); then
        echo -e "{{ok}} Collections installed."
    else
        echo "${OUTPUT}"
        exit 1
    fi

# Create virtual environment and install Python packages
[group('setup')]
install-venv: _non-root _python3
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Setting up virtual environment..."
    if [ ! -f requirements.txt ]; then
        echo -e "{{skip}} No requirements.txt file found."
        exit 0
    fi
    test -d "{{venv}}" || python3 -m venv "{{venv}}"
    "{{venv}}"/bin/python -m pip install -q --upgrade pip
    "{{venv}}"/bin/pip install -q --upgrade -r requirements.txt
    echo -e "{{ok}} Virtual environment ready."

# ── update ─────────────────────────────────────────────────────────────────────

# Update requirements.yml commit hashes to latest HEAD
[group('update')]
update: _non-root (_require "requirements.yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Updating requirements.yml commit hashes..."
    COMMITS=$(grep -E "version:" requirements.yml | cut -d ":" -f 2 | tr -d ' ')
    REPOS=$(grep -E "name:" requirements.yml | grep "tesseract" | cut -d ":" -f 2,3 | tr -d ' ')
    COUNTER=1
    for COMMIT in ${COMMITS}; do
        REPO=$(echo ${REPOS} | cut -d ' ' -f "${COUNTER}")
        echo -e "{{info}} Fetching HEAD for ${REPO}"
        NEW_COMMIT=$(git ls-remote "${REPO}" HEAD | cut -f1)
        echo -e "{{info}} ${COMMIT} → ${NEW_COMMIT}"
        sed -i "s/${COMMIT}/${NEW_COMMIT}/g" requirements.yml
        COUNTER=$((COUNTER + 1))
    done
    echo -e "{{ok}} requirements.yml updated."

# Sync all role molecule.yml files from repo root template
[group('update')]
update-molecule: _non-root (_require "molecule.yml") (_require "roles")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Syncing molecule.yml to all roles..."
    for moleculedir in roles/*/molecule; do
        if [ ! -f "${moleculedir}/default/molecule.yml" ]; then
            echo -e "{{err}} No molecule.yml found for role: ${moleculedir}" >&2
            exit 1
        fi
        if cmp -s molecule.yml "${moleculedir}/default/molecule.yml"; then
            echo -e "{{skip}} ${moleculedir}: already up to date, skipping."
        else
            cp molecule.yml "${moleculedir}/default/molecule.yml"
            echo -e "{{ok}} ${moleculedir}: updated."
        fi
    done
    echo -e "{{ok}} molecule.yml sync complete."

# ── test ───────────────────────────────────────────────────────────────────────

# Run molecule test for a role (omit role to test repo root)
[group('test')]
[arg("scenario", long, short="s")]
test role="" scenario="default": _venv _docker _docker-access
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{role}}" ]; then
        echo -e "{{info}} Testing role: {{role}} (scenario={{scenario}})"
    else
        echo -e "{{info}} Testing repo root (scenario={{scenario}})"
    fi
    just molecule "test" "{{role}}" --scenario "{{scenario}}"
    echo -e "{{ok}} Test passed."

# Test roles modified since origin/main
[arg("scenario", long, short="s")]
[group('test')]
test-changed scenario="default": _venv _docker _docker-access (_require "roles")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Testing changed roles since origin/main (scenario={{scenario}})"
    if ! git fetch origin main 2>/dev/null; then
        echo -e "{{skip}} Could not fetch origin/main, using local ref."
    fi
    roles=$(git diff --name-only "$(git merge-base HEAD origin/main)" \
        | awk -F/ '/^roles\// {print $1 "/" $2}' | sort -u)
    if [ -z "${roles}" ]; then
        echo -e "{{ok}} No changed roles to test."
        exit 0
    fi
    for roledir in ${roles}; do
        role=$(basename "${roledir}")
        moleculedir="${roledir}/molecule"
        if [ -f "${moleculedir}/{{scenario}}/molecule.yml" ]; then
            echo -e "{{info}} Testing: ${moleculedir}"
            INSTANCE_NAME="molecule-${RANDOM}" just molecule "test" "${role}" --scenario "{{scenario}}"
            echo -e "{{ok}} ${moleculedir} passed."
        else
            echo -e "{{skip}} ${moleculedir}: no molecule.yml, skipping."
        fi
    done
    echo -e "{{ok}} All changed roles tested."

# Test every role, optionally across multiple distros
[group('test')]
[arg("scenario", long, short="s")]
[arg("distros", long, short="d")]
test-all distros="" scenario="default": _venv _docker _docker-access (_require "roles")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Testing all roles (scenario={{scenario}})"
    distro_list="{{distros}}"
    distro_list="${distro_list//,/ }"
    for moleculedir in roles/*/molecule; do
        role=$(basename "$(dirname "${moleculedir}")")
        if [ ! -f "${moleculedir}/{{scenario}}/molecule.yml" ]; then
            echo -e "{{skip}} ${moleculedir}: no molecule.yml, skipping."
            continue
        fi
        if [ -z "${distro_list}" ]; then
            echo -e "{{info}} Testing: ${moleculedir}"
            INSTANCE_NAME="molecule-${RANDOM}" just molecule "test" "${role}" --scenario "{{scenario}}"
            echo -e "{{ok}} ${moleculedir} passed."
        else
            for distro in ${distro_list}; do
                echo -e "{{info}} Testing: ${moleculedir} on ${distro}"
                INSTANCE_NAME="molecule-${RANDOM}" MOLECULE_DISTRO="${distro}" just molecule "test" "${role}" --scenario "{{scenario}}"
                echo -e "{{ok}} ${moleculedir} [${distro}] passed."
            done
        fi
    done
    echo -e "{{ok}} All roles tested."

# ── molecule ───────────────────────────────────────────────────────────────────

# Run a molecule command for a role
[no-exit-message]
[group('molecule')]
[arg("scenario", long, short="s")]
[arg("destroy", long, short="d")]
molecule cmd="test" role="" scenario="default" destroy="true": _venv _docker _docker-access
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" == "" ]; then
        moleculedir="./molecule"
    else
        moleculedir="roles/{{role}}/molecule"
    fi
    if [ ! -f "${moleculedir}/{{scenario}}/molecule.yml" ]; then
        echo -e "{{err}} No molecule.yml found: ${moleculedir}/{{scenario}}/molecule.yml" >&2
        exit 1
    fi
    args=(--scenario-name "{{scenario}}")
    if [ "{{cmd}}" == "test" ]; then
        if [ "{{destroy}}" == "true" ]; then
            args+=(--destroy always)
        else
            args+=(--destroy never)
        fi
    fi
    VENV_DIR="$(realpath "{{venv}}")"
    (
        cd "$(dirname "${moleculedir}")"
        PATH="${VENV_DIR}/bin:${PATH}" VIRTUAL_ENV="${VENV_DIR}" "${VENV_DIR}/bin/molecule" "{{cmd}}" "${args[@]}"
    )

# ── deploy ─────────────────────────────────────────────────────────────────────

# Run the playbook with optional tag and host filters
[group('deploy')]
[arg("limit", long, short="l")]
[arg("tags", long, short="t")]
deploy env="prod" limit="all" tags="all": _venv (_require "inventories/" + env + "/hosts.yml") (_require "playbooks/" + env + ".yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Deploying playbook for environment: {{env}} (tags={{tags}}, limit={{limit}})"
    {{venv}}/bin/ansible-playbook -i inventories/{{env}}/hosts.yml playbooks/{{env}}.yml --tags {{tags}} --limit {{limit}}
    echo -e "{{ok}} Playbook deployed."

# Deploy a role from a local path directly against hosts
[group('deploy')]
[arg("limit", long, short="l")]
deploy-role path env="prod" limit="all": _venv (_require path) (_require path + "/tasks/main.yml") (_require "inventories/" + env + "/hosts.yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Deploying role: {{path}} on environment: {{env}} (limit={{limit}})"
    role_path=$(realpath "{{path}}")
    role_name=$(basename "${role_path}")
    roles_dir=$(dirname "${role_path}")
    tmpfile=$(mktemp /tmp/run-role-XXXXXX.yml)
    trap "rm -f ${tmpfile}" EXIT
    printf -- '---\n- hosts: all\n  roles:\n    - %s\n' "${role_name}" > "${tmpfile}"
    ANSIBLE_ROLES_PATH="${roles_dir}" {{venv}}/bin/ansible-playbook \
        -i inventories/{{env}}/hosts.yml \
        --limit {{limit}} \
        --become \
        "${tmpfile}"
    echo -e "{{ok}} Role deployed."

# Dry-run the playbook (--check --diff)
[group('deploy')]
[arg("limit", long, short="l")]
[arg("tags", long, short="t")]
check env="prod" limit="all" tags="all": _venv (_require "inventories/" + env + "/hosts.yml") (_require "playbooks/" + env + ".yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Dry-run playbook for environment: {{env}} (tags={{tags}}, limit={{limit}})"
    ANSIBLE_DISPLAY_SKIPPED_HOSTS=false ANSIBLE_DISPLAY_OK_HOSTS=false \
        {{venv}}/bin/ansible-playbook -i inventories/{{env}}/hosts.yml playbooks/{{env}}.yml --tags {{tags}} --limit {{limit}} --diff --check
    echo -e "{{ok}} Dry-run complete."

# ── ops ────────────────────────────────────────────────────────────────────────

# Run an ad-hoc shell command on hosts
[group('ops')]
[arg("limit", long, short="l")]
shell cmd env="prod" limit="all": _venv (_require "inventories/" + env + "/hosts.yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Running shell command on environment: {{env}} (limit={{limit}})"
    {{venv}}/bin/ansible -i inventories/{{env}}/hosts.yml all -b -m shell -a "{{cmd}}" --limit {{limit}}
    echo -e "{{ok}} Shell command executed."

# Edit the encrypted vault for the environment
[group('ops')]
vault env="prod": _venv (_require "inventories/" + env + "/group_vars/all.yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Editing Ansible Vault for environment: {{env}}"
    {{venv}}/bin/ansible-vault edit inventories/{{env}}/group_vars/all.yml
    echo -e "{{ok}} Vault edited."

# Open SSH session to a host
[group('ops')]
ssh host env="prod": _venv (_require "inventories/" + env + "/hosts.yml")
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Opening SSH session to host: {{host}} in environment: {{env}}"

    EXPR="{{ '{{' }} [
        ansible_ssh_host | default(ansible_host) | default(inventory_hostname),
        ansible_user | default(''),
        ansible_ssh_pass | default(''),
        ansible_ssh_private_key_file | default('')
    ] | join('%%') {{ '}}' }}"
    OUTPUT=$(
        {{venv}}/bin/ansible \
            -i "inventories/{{env}}/hosts.yml" \
            "{{host}}" \
            -m debug -o \
            -a "msg=${EXPR}" \
            2>/dev/null
    )
    IFS=$'\t' read -r SSH_HOST SSH_USER SSH_PASS SSH_KEY < <(
        grep -oP '"msg": "\K[^"]+' <<< "${OUTPUT}" | awk -F'%%' -v OFS='\t' '{print $1,$2,$3,$4}') || true

    if [ -z "${SSH_HOST}" ]; then
        echo -e "{{err}} Host '{{host}}' not found in inventory." >&2
        exit 1
    fi
    echo -e "{{info}} Connecting to ${SSH_USER}@${SSH_HOST}"
    if [ -n "${SSH_KEY}" ]; then
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}"
    elif [ -n "${SSH_PASS}" ]; then
        SSHPASS="${SSH_PASS}" sshpass -e ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}"
    else
        ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}"
    fi
    echo -e "{{ok}} SSH session closed."

# Power off and unregister all VirtualBox VMs
[group('ops')]
[confirm]
delete-vms:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{info}} Powering off and unregistering all VirtualBox VMs..."
    VBoxManage list runningvms | awk '{print $2}' | xargs -I{} VBoxManage controlvm {} poweroff
    VBoxManage list vms | awk '{print $2}' | xargs -I{} VBoxManage unregistervm {}
    rm -rf ~/VirtualBox\ VMs/*
    echo -e "{{ok}} All VirtualBox VMs deleted."
