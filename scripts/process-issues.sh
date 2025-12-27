#!/bin/bash
# process-issues.sh - Process issues through a phase
# Usage: ./process-issues.sh <repo> <json_file> <phase>
#
# Phases:
#   planning     - Plan issues, create epic with child tasks, create approval blocker
#   implement    - Create worktree and implement
#   lint         - Run lint/type/prettier, Claude fixes if fails
#   review       - Code review
#   test         - Run tests
#   human-review - Set up for human review
#   merge        - Rebase and merge (Claude resolves conflicts if needed)

set -e

REPO="$1"
JSON_FILE="$2"
PHASE="$3"

if [ -z "$REPO" ] || [ -z "$JSON_FILE" ] || [ -z "$PHASE" ]; then
  echo "Usage: $0 <repo> <json_file> <phase>"
  exit 1
fi

cd "$REPO"

# ═══════════════════════════════════════════════════════════════════════════
# SESSION MANAGEMENT - Enables Claude to ask questions and resume later
# ═══════════════════════════════════════════════════════════════════════════

get_or_create_session() {
  local ISSUE_ID="$1"
  local SESSION_ID=$(bd comments "$ISSUE_ID" --json 2>/dev/null | jq -r '.[] | select(.text | startswith("claude-session:")) | .text | sub("claude-session:"; "")' | head -1)

  if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(uuidgen)
    bd comments add "$ISSUE_ID" "claude-session:$SESSION_ID" >/dev/null 2>&1
  fi
  echo "$SESSION_ID"
}

claude_session_exists() {
  local SESSION_ID="$1"
  # Check if session file exists in Claude's project sessions directory
  # Sessions are stored as {session-id}/session.jsonl or similar
  local SESSION_DIR="$HOME/.claude/projects"
  if find "$SESSION_DIR" -name "${SESSION_ID}*" -type d 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

run_claude() {
  local ISSUE_ID="$1"
  local PROMPT="$2"
  local SESSION_ID=$(get_or_create_session "$ISSUE_ID")

  # Check if resuming from a previous session
  if claude_session_exists "$SESSION_ID" >/dev/null 2>&1; then
    echo "Resuming session $SESSION_ID for issue $ISSUE_ID"
    claude --resume "$SESSION_ID" --print --dangerously-skip-permissions "$PROMPT" 2>&1
  else
    echo "Starting new session $SESSION_ID for issue $ISSUE_ID"
    claude --session-id "$SESSION_ID" --print --dangerously-skip-permissions "$PROMPT" 2>&1
  fi
}

# Common instructions for all phases - enables ask-first behavior
COMMON_INSTRUCTIONS="
IMPORTANT: If you need clarification or are unsure about something:
1. Do NOT guess or make assumptions
2. Create a wisp blocker immediately (ephemeral, won't pollute beads):
   bd create --wisp --title \"Question: <brief question>\" \\
     --description \"<detailed context and options>\" \\
     --labels needs-human-input --silent
3. Make the main issue depend on it:
   bd dep add \$ISSUE_ID <wisp-id>
4. Stop immediately - do not continue working
5. Human will close the wisp with their answer: bd close <wisp-id> --reason \"answer\"
"

process_issue() {
  local ISSUE_ID="$1"
  local ISSUE_TITLE="$2"
  local WORKTREE="${REPO}/.worktrees/${ISSUE_ID}"
  local BRANCH="work/${ISSUE_ID}"

  # Get issue description (bd show --json returns an array)
  local ISSUE_DESC=$(bd show "$ISSUE_ID" --json 2>/dev/null | jq -r '.[0].description // ""')

  case "$PHASE" in
    planning)
      echo "Planning: $ISSUE_ID - $ISSUE_TITLE"
      bd label remove "$ISSUE_ID" needs-planning 2>/dev/null || true
      bd label add "$ISSUE_ID" planning

      # Run Claude to create a structured plan with child tasks
      echo "Running Claude for planning..."
      run_claude "$ISSUE_ID" "
You are planning issue $ISSUE_ID: $ISSUE_TITLE
Description: $ISSUE_DESC

Your task:
1. Read the issue details with: bd show $ISSUE_ID
2. Break down the work into 2-5 concrete tasks
3. Update the issue type to 'feature' or 'epic' if it makes sense: bd update $ISSUE_ID --type feature
4. Create child tasks under this issue using: bd create --title \"Task title\" --parent $ISSUE_ID --type task
5. Add a summary comment: bd comments add $ISSUE_ID \"Plan: <brief summary>\"

Keep tasks small and actionable. Each task should be implementable in one session.
Do NOT implement anything - just create the plan structure.

$COMMON_INSTRUCTIONS
" || echo "Claude planning completed"

      bd label remove "$ISSUE_ID" planning 2>/dev/null || true
      bd label add "$ISSUE_ID" pending-approval

      # Create approval issue, then make original depend on it (blocks it)
      APPROVAL_ID=$(bd create --title "Approve plan for $ISSUE_ID" --labels needs-human-approval --silent)
      bd dep add "$ISSUE_ID" "$APPROVAL_ID"
      echo "Created blocker: $APPROVAL_ID"
      ;;

    implement)
      echo "Implementing: $ISSUE_ID - $ISSUE_TITLE"

      # Create worktree if needed
      if [ ! -d "$WORKTREE" ]; then
        git worktree add "$WORKTREE" -b "$BRANCH" 2>/dev/null || \
        git worktree add "$WORKTREE" "$BRANCH" 2>/dev/null || \
        echo "Worktree exists or error"
      fi

      bd label remove "$ISSUE_ID" approved 2>/dev/null || true
      bd label add "$ISSUE_ID" implementing
      bd update "$ISSUE_ID" --status in_progress 2>/dev/null || true

      # Run Claude to implement - in the worktree
      echo "Running Claude for implementation in $WORKTREE..."
      cd "$WORKTREE"
      run_claude "$ISSUE_ID" "
Implement issue $ISSUE_ID: $ISSUE_TITLE
Description: $ISSUE_DESC

Instructions:
1. Read full context with: bd show $ISSUE_ID
2. Check for any child tasks: bd list --parent $ISSUE_ID
3. Implement the required changes
4. Commit your changes with a clear message
5. Do NOT close the issue - just implement and commit

$COMMON_INSTRUCTIONS
" || echo "Claude implementation completed"
      cd "$REPO"

      bd label remove "$ISSUE_ID" implementing 2>/dev/null || true
      bd label add "$ISSUE_ID" to-lint
      ;;

    lint)
      echo "Linting: $ISSUE_ID"
      bd label remove "$ISSUE_ID" to-lint 2>/dev/null || true
      bd label add "$ISSUE_ID" linting

      cd "$WORKTREE"

      # Run lint/type/format checks using env vars (set per-repo in beads-main.yaml)
      # Defaults: LINT_CMD, TYPE_CMD, FORMAT_CMD
      # Examples:
      #   JS:     LINT_CMD="npm run lint" TYPE_CMD="npm run typecheck" FORMAT_CMD="npx prettier --write ."
      #   Python: LINT_CMD="ruff check . --fix" TYPE_CMD="ty check ." FORMAT_CMD="ruff format ."

      LINT_FAILED=0

      # Run format first (auto-fixes)
      if [ -n "$FORMAT_CMD" ]; then
        echo "Running format: $FORMAT_CMD"
        eval "$FORMAT_CMD" 2>&1 || true
      fi

      # Run lint (may auto-fix with --fix flags)
      if [ -n "$LINT_CMD" ]; then
        echo "Running lint: $LINT_CMD"
        eval "$LINT_CMD" 2>&1 || LINT_FAILED=1
      fi

      # Run type check
      if [ -n "$TYPE_CMD" ]; then
        echo "Running type check: $TYPE_CMD"
        eval "$TYPE_CMD" 2>&1 || LINT_FAILED=1
      fi

      # If linting failed, use Claude to fix
      if [ "$LINT_FAILED" -eq 1 ]; then
        echo "Lint/type check failed, running Claude to fix..."
        run_claude "$ISSUE_ID" "
Lint/type checks failed for issue $ISSUE_ID.

Commands that failed:
- Lint: $LINT_CMD
- Type: $TYPE_CMD

Run the commands again to see errors, then fix them.
After fixing, commit with message: 'fix: lint and type issues'
Context: bd show $ISSUE_ID

$COMMON_INSTRUCTIONS
" || echo "Claude lint fix completed"
      fi

      # Commit any formatting changes
      git add -A
      git diff --cached --quiet || git commit -m "style: auto-format and lint fixes" 2>/dev/null || true

      cd "$REPO"

      bd label remove "$ISSUE_ID" linting 2>/dev/null || true
      bd label add "$ISSUE_ID" to-review
      ;;

    review)
      echo "Reviewing: $ISSUE_ID"
      bd label remove "$ISSUE_ID" to-review 2>/dev/null || true
      bd label add "$ISSUE_ID" reviewing

      cd "$WORKTREE"
      run_claude "$ISSUE_ID" "
Review the changes for issue $ISSUE_ID.
Context: bd show $ISSUE_ID

1. Run: git log --oneline main..HEAD to see commits
2. Run: git diff main to see all changes
3. Review like Linus Torvalds - be direct and critical
4. Check for: bugs, security issues, performance problems, code style
5. Add your review: bd comments add $ISSUE_ID \"Review: <your assessment>\"

If there are issues, list them clearly. If it looks good, say 'LGTM'.

$COMMON_INSTRUCTIONS
" || echo "Claude review completed"
      cd "$REPO"

      bd label remove "$ISSUE_ID" reviewing 2>/dev/null || true
      bd label add "$ISSUE_ID" reviewed
      ;;

    test)
      echo "Testing: $ISSUE_ID"
      bd label remove "$ISSUE_ID" reviewed 2>/dev/null || true
      bd label add "$ISSUE_ID" testing

      cd "$WORKTREE"
      run_claude "$ISSUE_ID" "
Test the implementation for issue $ISSUE_ID.
Context: bd show $ISSUE_ID

1. Find and run existing tests (npm test, pytest, cargo test, go test, etc.)
2. If no tests exist, do a quick manual verification
3. Report results: bd comments add $ISSUE_ID \"Tests: <PASS/FAIL with details>\"

Be thorough but quick.

$COMMON_INSTRUCTIONS
" || echo "Claude testing completed"
      cd "$REPO"

      bd label remove "$ISSUE_ID" testing 2>/dev/null || true
      bd label add "$ISSUE_ID" tested
      ;;

    human-review)
      echo "Setting up human review: $ISSUE_ID"
      bd label remove "$ISSUE_ID" tested 2>/dev/null || true
      bd label add "$ISSUE_ID" awaiting-human-review

      # Create human review issue, then make original depend on it
      REVIEW_ID=$(bd create --title "Human review needed: $ISSUE_ID" --labels needs-human-review --silent)
      bd dep add "$ISSUE_ID" "$REVIEW_ID"
      echo "Created blocker: $REVIEW_ID"

      # TODO: Start cloudflared here for remote access
      echo "Human review required - close $REVIEW_ID when approved"
      ;;

    merge)
      echo "Merging: $ISSUE_ID"

      cd "$WORKTREE"

      # Step 1: Try to rebase on main
      echo "Rebasing $BRANCH on main..."
      git fetch origin main 2>/dev/null || true

      if ! git rebase main 2>&1; then
        echo "Rebase failed - conflicts detected. Using Claude to resolve..."

        # Get conflict info
        CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")

        if [ -n "$CONFLICTS" ]; then
          run_claude "$ISSUE_ID" "
There are merge conflicts while rebasing issue $ISSUE_ID on main.

Context: bd show $ISSUE_ID

Conflicting files:
$CONFLICTS

Instructions:
1. For each conflicting file, examine the conflict markers (<<<<<<< ======= >>>>>>>)
2. Understand both versions and merge them intelligently
3. Remove all conflict markers
4. Run: git add <file> for each resolved file
5. Run: git rebase --continue
6. If rebase still fails, run: git rebase --abort and report the issue

Preserve functionality from both branches where possible.

$COMMON_INSTRUCTIONS
" || echo "Claude conflict resolution completed"
        else
          # No conflicts but rebase failed for other reason
          git rebase --abort 2>/dev/null || true
          echo "Rebase failed for unknown reason"
        fi
      fi

      cd "$REPO"

      # Step 2: Fast-forward merge to main
      git checkout main
      if git merge --ff-only "$BRANCH" 2>&1; then
        echo "Merged successfully"
        git worktree remove "$WORKTREE" --force 2>/dev/null || true
        git branch -d "$BRANCH" 2>/dev/null || true
        bd label remove "$ISSUE_ID" human-approved 2>/dev/null || true
        bd close "$ISSUE_ID" --reason "Merged to main"
        echo "Merged and closed: $ISSUE_ID"
      else
        echo "Fast-forward merge failed - branch may need manual intervention"
        bd label add "$ISSUE_ID" merge-failed 2>/dev/null || true
        # Create blocker for manual resolution
        MERGE_ISSUE=$(bd create --title "Merge failed for $ISSUE_ID - manual intervention needed" --labels needs-human-approval --silent)
        bd dep add "$ISSUE_ID" "$MERGE_ISSUE"
        echo "Created merge blocker: $MERGE_ISSUE"
      fi
      ;;

    *)
      echo "Unknown phase: $PHASE"
      exit 1
      ;;
  esac
}

# Process each issue from JSON file
jq -r '.[].id' "$JSON_FILE" 2>/dev/null | while read ISSUE_ID; do
  [ -z "$ISSUE_ID" ] && continue
  ISSUE_TITLE=$(jq -r --arg id "$ISSUE_ID" '.[] | select(.id==$id) | .title' "$JSON_FILE")
  process_issue "$ISSUE_ID" "$ISSUE_TITLE"
done
