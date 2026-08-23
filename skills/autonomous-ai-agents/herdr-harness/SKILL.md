---
name: herdr-harness
description: Orchestrate persistent Codex, Claude, Hermes, and other coding-agent terminals through Herdr, locally or on an SSH workbox. Use for team coding, parallel worktrees, long-running agent sessions, supervision, and recovery after disconnects.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [Coding-Agent, Herdr, SSH, Worktrees, Team, Orchestration]
    related_skills: [codex, claude-code, hermes-agent]
---

# Herdr Team Harness

Use the `herdr_harness` tool as the control plane for persistent coding sessions. SSH is only the transport; Herdr owns terminal persistence and lifecycle state; Git worktrees isolate concurrent changes.

## Mandatory Rules

1. Run `doctor` before the first task in a session.
2. Create one worktree per active task or agent. Never run two active agents in the same worktree.
3. Use the IDs returned by `task_create`; do not guess workspace or pane IDs.
4. Start interactive coding CLIs with `agent_start`, not `pane_run`.
5. Use `agent_wait` for lifecycle state and `agent_read` for evidence. Use `pane_wait` only for exact terminal output.
6. Read an agent before sending keys when it is blocked or unknown.
7. Never send secrets, SSH private keys, API keys, or production credentials in prompts.
8. Do not stop/delete sessions, close unowned panes, or force-remove worktrees. Those destructive operations are intentionally absent from the normal tool surface.
9. Keep Hermes approvals enabled. Never request `HERMES_YOLO_MODE` for a shared workbox.

## Preflight

```
herdr_harness(action="doctor", profile="hermes-bot")
herdr_harness(action="status", profile="hermes-bot")
herdr_harness(action="workspace_ensure", profile="hermes-bot", label="hermes-agent")
```

If `doctor` fails, report the failing check exactly. Typical causes are an unreachable SSH alias, missing Herdr on the workbox, a repository path mismatch, or a missing agent CLI.

## Standard Task Flow

### 1. Create an isolated worktree

```
herdr_harness(
  action="task_create",
  profile="hermes-bot",
  task="issue-142-auth-timeout",
  branch="agent/issue-142-auth-timeout",
  base="main",
  label="issue-142"
)
```

Capture `workspace_id`, `pane_id`, branch, and path from the response.

### 2. Start the coding agent in the returned pane

```
herdr_harness(
  action="agent_start",
  profile="hermes-bot",
  agent_name="issue-142",
  agent_kind="codex",
  pane_id="<pane_id>",
  start_timeout_ms=30000
)
```

Agent names must start with a lowercase letter and contain only lowercase letters, digits, `_`, or `-`.

### 3. Submit one complete task prompt

```
herdr_harness(
  action="agent_prompt",
  profile="hermes-bot",
  target="issue-142",
  prompt="Fix issue #142. Reproduce the timeout, add a regression test, implement the smallest safe change, run the focused test suite, and summarize changed files and remaining risk. Do not modify unrelated files.",
  timeout_ms=180000
)
```

A good prompt contains the objective, constraints, expected tests, scope exclusions, and required final evidence.

### 4. Observe state and output

```
herdr_harness(
  action="agent_wait",
  profile="hermes-bot",
  target="issue-142",
  until=["idle", "done", "blocked"],
  timeout_ms=180000
)

herdr_harness(
  action="agent_read",
  profile="hermes-bot",
  target="issue-142",
  source="recent-unwrapped",
  lines=300
)
```

Do not treat `idle` as proof that the task is correct. Verify tests and inspect the diff.

### 5. Validate inside the same worktree

Use the pane only for noninteractive validation commands:

```
herdr_harness(
  action="pane_run",
  profile="hermes-bot",
  pane_id="<pane_id>",
  command="git status --short && pytest -q tests/path/to/focused_test.py"
)
```

Then read the pane:

```
herdr_harness(
  action="pane_read",
  profile="hermes-bot",
  pane_id="<pane_id>",
  source="recent-unwrapped",
  lines=300
)
```

The normal Hermes dangerous-command guard applies to `pane_run`.

## Parallel Work

Create a separate task/worktree/pane/agent tuple for every issue. Parallel agents may share the same base repository but must have different branches and worktree paths.

Recommended naming:

- Branch: `agent/<ticket>-<slug>`
- Worktree label: `<ticket>`
- Agent: `<ticket>-<short-role>`
- Session: `hermes-<project>-<unix-user>`

Before delegating related tasks in parallel, define file ownership boundaries. If two tasks need the same files, serialize them or create an explicit integration task after both branches are ready.

## Blocked Agent Recovery

1. Read current state and recent output.
2. Determine whether the agent is asking for input, waiting on approval, or stuck in an interactive program.
3. Prefer a clarifying prompt over raw keys.
4. Use `agent_keys` only for terminal control such as `esc`, `ctrl+c`, arrows, or `enter`.

```
herdr_harness(action="agent_read", target="issue-142", lines=250)
herdr_harness(action="agent_keys", target="issue-142", keys=["esc"])
herdr_harness(action="agent_prompt", target="issue-142", prompt="Continue without changing the public API. Use the existing test fixture.")
```

Never send `ctrl+c` blindly to an agent that may be writing files or running a migration.

## Disconnection and Resume

Herdr sessions survive client disconnects. After reconnecting:

```
herdr_harness(action="status", profile="hermes-bot")
herdr_harness(action="agent_list", profile="hermes-bot")
herdr_harness(action="worktree_list", profile="hermes-bot")
```

Resume from the reported agent and workspace IDs. Do not create a replacement task until confirming the original worktree and agent are gone or intentionally abandoned.

## Human Attach

Humans attach from their own terminal with:

```
herdr-hermesctl --profile <profile> attach
```

The preferred remote attach path uses the local Herdr client and an OpenSSH alias, preserving local clipboard integration. `attach --via-ssh` is the fallback.

## Handoff Checklist

- Branch and worktree identified
- Agent state settled
- Diff inspected
- Focused tests executed and output captured
- Broader tests run when warranted
- No secrets or generated credentials added
- Commit/PR created through the normal GitHub workflow
- Worktree removal deferred until the branch is pushed and no longer needed
