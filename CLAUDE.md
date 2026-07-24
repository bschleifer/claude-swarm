# Claude Swarm — Project Guide

## What This Is
A bash script (`swarm.sh`) that launches and manages multiple Claude Code agents in tmux panes.

## Architecture
- **Single file**: all logic lives in `swarm.sh`
- **Subcommands**: `status`, `continue`, `send`, `restart`, `kill`, `watch` — dispatched near line 372
- **Launch mode**: interactive picker → tmux session builder → attach
- **Watch loop**: background process polls pane states every 5 seconds

## Key Patterns
- `detect_pane_state()` reads tmux pane content to classify: IDLE / WORKING / EXITED
- `@swarm_state` per-pane tmux user option stores the last detected state (set by `cmd_watch`)
- `pane-border-format` uses tmux conditionals to read `@swarm_state` and color-code borders
- OSC escape sequences are written to the **client TTY** (not pane TTY) to avoid corrupting Claude's TUI
- Hotkeys use `^b` prefix (Ctrl-b): `c` = continue, `C` = continue all, `r` = restart, `s` = status popup

## Conventions
- Use `tmux set -p -t TARGET @swarm_state "STATE"` to update pane state
- Never write escape sequences to pane TTYs — always use `tmux list-clients -F '#{client_tty}'`
- Session naming: auto-derived from selection labels, sanitized for tmux
- Groups defined in `AGENT_GROUPS` array, individual repos auto-detected from `~/projects/`

## Swarm / Conductor

When working on the swarm/conductor system: never inject text into tmux panes while the user may be typing. Always use targeted send-keys with proper Enter key submission. Throttle polling to at least 30-second intervals. Never run idle polling loops without a shutdown mechanism.

### Headless Conductor Pattern
Instead of infinite polling loops, use bounded headless invocations with clear exit conditions:
```bash
claude -p "Check swarm agent status in tmux. If any agent needs approval, approve it. If any agent is idle and there are pending tasks, assign one. If all agents are idle and no tasks remain, output SWARM_COMPLETE." \
  --allowedTools "Bash,Read" --max-turns 10
```
Wrap in a bash loop with proper sleep and exit detection:
```bash
while true; do
  OUTPUT=$(claude -p "..." --allowedTools "Bash,Read" --max-turns 10 2>&1)
  echo "$OUTPUT" >> swarm-conductor.log
  if echo "$OUTPUT" | grep -q "SWARM_COMPLETE"; then
    echo "All agents idle, no tasks remain. Exiting."
    break
  fi
  sleep 30
done
```
Key rules: always set `--max-turns`, always define an exit signal, always log output, always sleep between cycles.

## General Rules

When the user shows a screenshot proving something is broken, do NOT claim it's correct. Trust the user's visual evidence over code assumptions, especially for UI color/theme rendering issues.

## Testing
- Run all tests: `./test/run-tests.sh`
- Run unit tests only: `./test/bats/bin/bats test/unit_*.bats`
- Run integration tests only: `./test/bats/bin/bats test/integration_*.bats`
- Launch: `./swarm.sh` (interactive) or `./swarm.sh -a` (all agents)
- Verify borders: heavy lines with colored state labels
- Verify watch: `swarm watch` updates `@swarm_state` and terminal title
- Check state: `tmux show -p -t SESSION:WIN.PANE @swarm_state`

## Secret Management

This repository uses the `miopea-secrets` Azure Key Vault as the authoritative source for secrets declared in `config/secrets.manifest.json`. Secret values never belong in Git. Local `.env` files are disposable, gitignored caches generated from the vault.

### Agent startup

Before work that requires credentials, run:

```bash
node scripts/secrets.mjs check
```

If required values are missing or stale, use the existing Azure session or authenticate, then pull and verify:

```bash
az login
node scripts/secrets.mjs pull
node scripts/secrets.mjs check
```

Do not run `az login` when the existing Azure session is valid.

`SECRET_REQUIRED` means run `node scripts/secrets.mjs check` before asking the user for a key or claiming credentials are unavailable.

### Agent safety rules

- Never commit `.env` files, private keys, service-account JSON, tokens, or decrypted secret exports.
- Never display secret values in command output, logs, messages, documentation, commits, or test fixtures.
- Never use broad environment-dump commands to inspect populated secret files or the complete process environment.
- Presence checks report only variable names and status.
- Use only secrets declared by this repository manifest; never add unrelated credentials just in case.
- `scripts/secrets.mjs` is read-only with respect to Key Vault.
- Do not create, update, disable, restore, purge, or delete a vault secret unless the user explicitly requests that external action.
- Pulling local secrets does not authorize changes to production, GitHub, Cloudflare, Apple, Google, or another provider.
- A successful local pull does not mean production was updated or deployed.

### Manifest changes

When the application begins using a new secret:

1. Search for the existing environment-variable convention.
2. Create or identify an appropriately scoped Key Vault secret.
3. Add only its vault-to-environment mapping to `config/secrets.manifest.json`.
4. Confirm the target environment file is gitignored.
5. Run:

   ```bash
   node --test scripts/secrets.node-test.mjs
   node scripts/secrets.mjs pull
   node scripts/secrets.mjs check
   ```

6. Inspect the staged diff and confirm it contains no secret value.

Manifest entries contain names and validation rules only, never values.

### Secret rotation

Only when explicitly authorized:

1. Update or generate the credential at its authoritative provider.
2. Store the replacement as a new version in `miopea-secrets`.
3. Pull and validate it locally.
4. Update production through the application deployment process.
5. Verify the real integration end to end.
6. Revoke the previous provider credential only after verification.

Changing Key Vault does not automatically refresh existing `.env` files or production configuration.

### Recovery

If a local `.env` is missing or damaged, remove only that exact gitignored file and regenerate it with `node scripts/secrets.mjs pull`. Never reconstruct values from documentation, shell history, commits, or another repository.

### Repository secret scope

This repository currently declares no Key Vault secrets. A successful check reporting zero required secrets is expected. Do not add credentials unless this application actually needs them.
