# beads-cron

A cron job that processes [beads](https://github.com/anthropics/beads) issues through Claude CLI.

Uses [dagu](https://github.com/dagu-org/dagu) to run a workflow every 5 minutes that checks for issues and runs Claude on them.

## What it actually does

```
Issue created → Claude plans it → You approve → Claude implements in worktree →
Lint runs → Claude reviews → Tests run → You review → Merge
```

There are human approval gates after planning and before merge. Claude pauses if it has questions.

## Requirements

- [beads](https://github.com/anthropics/beads) - `bd` CLI for issue tracking
- [Claude CLI](https://github.com/anthropics/claude-code) - `claude` command
- [dagu](https://github.com/dagu-org/dagu) - runs the cron workflow
- `jq`, `uuidgen`

## Setup

1. Clone this repo

2. Edit `dags/beads-main.yaml` to add your repos:
   ```yaml
   steps:
     - name: my-project
       call: beads-repo-check
       params: >-
         REPO=/path/to/your/project
         LINT_CMD=npm run lint
         TYPE_CMD=npm run typecheck
         FORMAT_CMD=npx prettier --write .
   ```

3. Run `bd init` in your target repo

4. Point dagu at `dags/beads-main.yaml`

## Language examples

**Python:**
```yaml
params: >-
  REPO=/path/to/project
  LINT_CMD=ruff check . --fix
  TYPE_CMD=ty check .
  FORMAT_CMD=ruff format .
```

**Rust:**
```yaml
params: >-
  REPO=/path/to/project
  LINT_CMD=cargo clippy --fix --allow-dirty
  TYPE_CMD=cargo check
  FORMAT_CMD=cargo fmt
```

**Go:**
```yaml
params: >-
  REPO=/path/to/project
  LINT_CMD=golangci-lint run --fix
  TYPE_CMD=go build ./...
  FORMAT_CMD=go fmt ./...
```

## Labels

Issues move through these states via labels:

- `needs-planning` → `pending-approval` → `approved` → `implementing` → `to-lint` → `to-review` → `reviewed` → `tested` → `awaiting-human-review` → `human-approved` → merged

## Ask & Resume

If Claude is unsure about something, it creates a wisp (ephemeral blocker issue) with its question and stops. Answer by closing the wisp:

```bash
bd close <wisp-id> --reason "Use approach A"
```

Next cron run, Claude resumes its session with your answer.

## Caveats

- Costs money (Claude API calls every phase)
- Sessions stored locally (`~/.claude/projects/`)
- Uses `--dangerously-skip-permissions` flag
- This is a weekend project, not production software

## Structure

```
dags/
  beads-main.yaml        # cron entry, repo list
  beads-repo-check.yaml  # workflow phases
scripts/
  process-issues.sh      # the actual logic
```

## License

MIT
