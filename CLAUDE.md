# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

beads-cron is a cron-based automation system that processes [beads](https://github.com/anthropics/beads) issues through Claude CLI. It uses [dagu](https://github.com/dagu-org/dagu) to orchestrate workflows that run every 5 minutes.

## Architecture

The system has three main components:

1. **dags/beads-main.yaml** - Cron entry point that lists repos to process (runs every 5 minutes)
2. **dags/beads-repo-check.yaml** - Per-repo workflow that runs all phases sequentially
3. **scripts/process-issues.sh** - Core bash script that handles each phase using Claude CLI

### Issue Lifecycle Flow

```
needs-planning → pending-approval → approved → implementing → to-lint → to-review → reviewed → tested → awaiting-human-review → human-approved → merged
```

Human approval gates occur after planning and before merge. Issues are blocked using beads dependencies.

### Session Management

Claude sessions are persisted via `claude --session-id` and resumed with `--resume`. Session IDs are stored as issue comments (`claude-session:<uuid>`).

### Ask & Resume Pattern

When Claude needs clarification:
1. Creates a wisp (ephemeral blocker) with `needs-human-input` label
2. Adds dependency from main issue to wisp
3. Stops processing

Human answers by closing the wisp with `bd close <wisp-id> --reason "answer"`. Next cron run resumes the session.

## Adding a New Repo

Edit `dags/beads-main.yaml`:

```yaml
steps:
  - name: my-project
    call: beads-repo-check
    params: >-
      REPO=/path/to/project
      LINT_CMD=npm run lint
      TYPE_CMD=npm run typecheck
      FORMAT_CMD=npx prettier --write .
```

## Key Commands

- `bd` - beads CLI for issue management
- `claude --session-id <id> --print --dangerously-skip-permissions "<prompt>"` - run Claude with persistent session
- `claude --resume <id> --print --dangerously-skip-permissions "<prompt>"` - resume previous session

## Workflow Phases (in scripts/process-issues.sh)

| Phase | Label Transition | Action |
|-------|-----------------|--------|
| planning | needs-planning → pending-approval | Claude creates child tasks, approval blocker created |
| implement | approved → to-lint | Creates git worktree, Claude implements |
| lint | to-lint → to-review | Runs LINT_CMD/TYPE_CMD/FORMAT_CMD, Claude fixes failures |
| review | to-review → reviewed | Claude does code review |
| test | reviewed → tested | Claude runs tests |
| human-review | tested → awaiting-human-review | Creates human review blocker |
| merge | human-approved → closed | Rebases on main, fast-forward merge, cleans up worktree |

## File Locations

- Worktrees: `${REPO}/.worktrees/${ISSUE_ID}`
- Branch naming: `work/${ISSUE_ID}`
- Temp files: `/tmp/beads-cron/`
- Claude sessions: `~/.claude/projects/`
