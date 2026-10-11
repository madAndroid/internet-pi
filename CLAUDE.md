# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
# Install required Ansible collections (ansible.posix, community.docker, community.general, community.sops)
ansible-galaxy collection install -r requirements.yml

# Run the full playbook against the host (inventory comes from ansible.cfg -> inventory.ini)
ansible-playbook main.yml

# Run from a given task onwards - note the explicit -e @config.yml (see Gotchas)
ansible-playbook main.yml -e @config.yml --start-at-task "Synchronize internet-monitoring directory."

# Lint
yamllint .
ansible-lint

# Decrypt / edit SOPS-encrypted secrets (requires the age private key in your keyring)
sops -d secrets/alertmanager.enc.yml
sops secrets/homebox.enc.yml
```

Tool versions are managed via asdf (see `.tool-versions`): Python 3.10.5, SOPS 3.8.1.

## Gotchas

- `main.yml` defines no tags, so `--tags <x>` runs nothing. Limit a run with `--start-at-task` or by toggling the `*_enable` flags in `config.yml`.
- `--start-at-task` also skips the `pre_tasks` that load `config.yml`, so pass it explicitly: `ansible-playbook main.yml -e @config.yml --start-at-task "<task name>"`.
- `--start-at-task` skips every task before it, including `community.sops.load_vars` in earlier task files. A task file must load every secret it templates itself, and templates must not use `| default(...)` for secrets. A silent default once wrote a wrong Grafana DB password and took Grafana down.
- Ansible refuses to run from Claude Code's `!` prompt ("Non-blocking file handles detected"). Run it in a normal terminal, or pipe its output through `cat` with stdin from `/dev/null`.
- Secrets in `secrets/` are SOPS/age-encrypted and decrypted automatically during playbook runs via `community.sops`. Both that and manual `sops -d` require the age private key in your keyring.
- All Docker image versions are pinned as `*_image_tag` vars in `config.yml` — bump them there when upgrading. Never use `:latest` (an unpinned Homebox pull once introduced a new required env var and crash-looped it).
- Major upgrades that migrate a database in place (e.g. Homarr v1 → v2) cannot be rolled back by changing the tag. Stop the container and back up its data first.

## Architecture

**Entry point**: `main.yml` — the sole playbook. It loads `config.yml` as vars in `pre_tasks`, then imports task files from `tasks/` gated by boolean flags in `config.yml`, in this order:

| Flag | Task file | What it sets up |
|---|---|---|
| (always) | `docker.yml`, `user-bin.yml` | Docker; scripts from `files/bin/` into the user's bin |
| `backups_enable` | `backups.yml` | Cron jobs for the Zimaboard backup scripts |
| `task_haproxy_enable` | `haproxy.yml` | Host HAProxy from `files/haproxy/haproxy.cfg` |
| `postgres_enable` | `postgres.yml` | Consolidated PostgreSQL + daily dumps |
| `monitoring_enable` | `internet-monitoring.yml` | Main Docker Compose stack |
| `pihole_enable` | `pi-hole.yml` | Pi-hole |
| `airgradient_enable` | `airgradient.yml` | AirGradient dashboards (needs `monitoring_enable`) |
| `starlink_enable` | `starlink.yml` | Starlink exporter (needs `monitoring_enable`) |
| `atuin_enable` | `atuin.yml` | Atuin sync server (own compose project) |

`shelly_enable` (also needs `monitoring_enable`) toggles the Shelly exporter inside the monitoring stack.

**Templates (`templates/*.j2`)** are rendered to the target host. The most important:
- `docker-compose.yml.j2` — main monitoring stack: Prometheus, Grafana, Alertmanager, Blackbox, Speedtest, Loki, Homarr, Homebox, Gotify, NetAlertX, Nginx file server
- `postgres-docker-compose.yml.j2` — the consolidated `postgres` container plus the `postgres-db-dumper` backup sidecar
- `prometheus.yml.j2` — scrape configuration; conditionally includes Shelly, AirGradient, Starlink, and extra job definitions from `monitoring_extra_configs`
- `prometheus-pinghosts.yaml.j2`, `prometheus-lab-hosts.yaml.j2`, `prometheus-essential-hosts.yaml.j2` — file-based service discovery targets driven by `monitoring_ping_hosts`, `monitoring_lab_hosts`, `monitoring_essential_hosts`

**Static files (`files/`)** are copied verbatim — notably `files/haproxy/haproxy.cfg`, the full HAProxy config for K8s API load-balancing and internal `*.int.stangl.co.za` routing (TLS on 443; each service is a backend pointing at its localhost port), and `files/bin/` (lab start/stop, backup and cert scripts).

### Consolidated PostgreSQL

One `postgres` container (Postgres 18, `pgdata` volume, `~/postgres/`) hosts the databases for apps that support it — currently `grafana`, `atuin`, `homebox` and `homarr`. Apps reach it as `postgres:5432` over the external Docker network `pg-net`, so their compose service must join `pg-net`. To add an app:
1. Add its DB name to `postgres_databases` in `config.yml` (this drives the daily `postgres-db-dumper` backups to `~/postgres/db_dumps`).
2. Put its DB password in `secrets/<app>.enc.yml`, load it in `tasks/postgres.yml`, and add the idempotent `CREATE ROLE` / `ALTER ROLE ... PASSWORD` / `CREATE DATABASE` block there.
3. Load the same secret in the app's own task file and pass it via the stack's `.env` (see Secrets).
4. Moving existing data from SQLite: start the app once against the empty DB so its own migrations build the schema, stop it, copy the rows, then restart. Keep the old SQLite file as a fallback.

### Secrets

SOPS/age encrypted, age public key in `.sops.yaml`. One file per concern: `alertmanager.enc.yml` (decrypted to a whole config file), `postgres.enc.yml` (superuser + Grafana DB password), `atuin.enc.yml`, `homebox.enc.yml` (API key pepper + DB password), `homarr.enc.yml` (DB password). Secrets reach containers through a `0600` `.env` written next to the compose file (`no_log: true`) and referenced as `${VAR:?...}` in the template, never inlined into world-readable rendered files. Homarr's `SECRET_ENCRYPTION_KEY` is still inlined in `docker-compose.yml.j2` and must not change (it decrypts stored integration credentials).

## Key Configuration Concepts

- **Target host**: `192.168.88.110` (`internet_pi` group in `inventory.ini`), user `andrew`. It is x86_64, not a Raspberry Pi, despite the naming.
- **Install prefix**: `config_dir: "~"` — everything lands under the Ansible user's home directory (`~/internet-monitoring`, `~/postgres`, `~/atuin`, ...).
- **Prometheus retention**: `prometheus_tsdb_retention_time` (currently `2y`).
- **Shelly devices**: defined in `config.yml` under `monitoring_extra_configs`; the Shelly exporter uses file-based service discovery with `shelly/config.yaml`.

## YAML Lint Rules

Max line length is 120 characters (warning only). `secrets/*`, `.github/workflows/stale.yml` and `.github/stale.yml` are excluded from yamllint. Ansible-lint skips `fqcn-builtins` and `no-handler`, and only warns on `yaml[line-length]`, `name[play]` and `no-changed-when`.

---

*Document Provenance: Generated by Claude Code (claude-sonnet-4-6) for andrew.stangl@dae.mn on 2026-05-02; restored and updated by Claude Code (claude-opus-5-5) on 2026-10-11.*
