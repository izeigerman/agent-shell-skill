---
name: agent-shell
description: Drive agent-shell sessions in a running Emacs via emacsclient — start claude/codex/gemini agents in git worktrees, send them prompts, read their output, kill sessions, and remove worktrees. Use when asked to spawn/delegate work to an Emacs agent, run an agent in a worktree, check on a running agent session, message a session, or clean up agent worktrees.
---

# agent-shell control

Control [agent-shell](https://github.com/xenodium/agent-shell) sessions inside the
user's already-running Emacs. Every operation goes through `emacsclient`, so the
session appears in Emacs exactly as if the user had started it — they can watch
it, answer its permission prompts, and take it over at any time.

## Locate the wrapper

Every command goes through one script, `bin/agent-shell-ctl`, which lives in this
skill's own directory. Resolve it once per session and reuse it; the examples
below all assume `$CTL`.

```bash
CTL=$(command -v agent-shell-ctl 2>/dev/null) ||
CTL=$(find -L ~/.claude ~/.config/claude ~/.agents \
        ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT"} \
        -maxdepth 6 -path '*/agent-shell/bin/agent-shell-ctl' -print -quit 2>/dev/null)
echo "$CTL"
```

Resolve it this way rather than assuming `~/.claude/skills/agent-shell/` — the
skill may be symlinked from a checkout, installed as a plugin, or linked onto
`PATH`. If `$CTL` comes back empty, tell the user the skill is not installed
where you can find it and ask for the path; do not guess.

## Preflight

Verify the Emacs server is reachable and agent-shell is loaded before anything
else:

```bash
"$CTL" agents
```

A failure means Emacs is not running, has no server (`M-x server-start`), or has
not loaded agent-shell. Say so rather than retrying — there is nothing to fall
back to.

On success it prints the identifiers accepted by `--agent`: `claude-code`,
`codex`, `gemini-cli`, `copilot`, `cursor`, `droid`, `goose`, `opencode`, and
others depending on the user's config.

`"$CTL" --help` lists every command and flag.

## Sessions

`list` and `status` print tab-separated fields:

```
NAME                STATUS  AGENT        TURNS  DIR                      SESSION-ID
Claude Agent @ bold-turing  ready  claude-code  2  /path/to/worktree      da9a9451-...
```

- **NAME** is the Emacs buffer name. Pass it to `--session`; a unique substring
  (e.g. `bold-turing`) is enough.
- **STATUS** is `ready` (idle), `busy` (working), or `blocked` (a permission
  dialog is waiting for a human in Emacs — see below).
- **TURNS** counts completed turns, which is how `--wait` knows a reply landed.
- **SESSION-ID** is the ACP session id, `-` until the session has initialized.

Buffer names are reused: kill a session and start another in the same
directory, and the new one gets the old name. A script that holds on to a
session across calls should record its SESSION-ID once and pass it as
`--session-id` on `status`, `config`, `output`, `send`, `wait` and `kill`,
in place of `--session`:

```bash
"$CTL" send --session-id da9a9451-... --prompt 'Also update the README.'
```

The id is checked in the same Emacs call that sends, reads or kills, so a
different session that took over the name can never be reached, and a session
the user renamed is still found. When no session has that id, the command exits
`1` with:

```
No agent session with ACP session id da9a9451-...
```

Treat that as the session being gone. A session whose id is still `-` never
matches.

A conversation resumed in Emacs can be open in two buffers with the same id.
`--session-id` alone then fails as ambiguous; add `--session` with the exact
buffer name (no substring match) to pick one. With both, the error reads
`No agent session NAME with ACP session id ID`.

`config` prints a session's model, mode and effort, tab-separated, with `-` for
any the agent does not have:

```
MODEL             MODE               THOUGHT-LEVEL
claude-haiku-5-5  bypassPermissions  low
```

A full `claude-code` model id reads back as given while the agent stays on the
alias it mapped that id to; a model picked by alias reads back as the alias.

## Spawning work in a new worktree

The common case — create a worktree, start an agent in it, hand it a task:

```bash
"$CTL" spawn \
  --agent claude-code \
  --repo /path/to/repo \
  --prompt-file /tmp/task.md \
  --mode acceptEdits \
  --wait --timeout 900
```

This creates `<agent-shell worktrees dir>/<random-name>` (honoring the user's
`agent-shell-dot-subdir-function`, usually `.agent-shell/worktrees/`), runs
`git worktree add`, starts the shell there, waits for the ACP session to
initialize, sends the prompt, then blocks until the turn completes.

Then read what it produced:

```bash
"$CTL" output --session bold-turing
```

Options worth knowing:

- `--name NAME` / `--branch BRANCH` / `--base REF` — control worktree naming and
  starting point instead of letting git and agent-shell pick.
- `--dir DIR` — run in an **existing** directory (an existing worktree, or the
  repo itself) instead of creating a new worktree.
- `--mode MODE` — ACP permission mode. For `claude-code`: `default`, `plan`,
  `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`; for `codex`:
  `read-only`, `workspace-write`, `agent`, `agent-full-access`. Without a
  permissive mode an unattended agent will stall at the first permission prompt.
- `--model MODEL` — agent-specific model id. `claude-code` lists aliases
  (`opus`, `sonnet`, `haiku`, ...) but also takes a full id such as
  `claude-opus-5-5`, which it maps onto the matching alias.
- `--effort LEVEL` — reasoning effort (the ACP `thought_level` option), e.g.
  `low`, `medium`, `high`. The levels on offer depend on the agent and model.
- `--display` — also show the buffer in Emacs. Off by default so spawning does
  not steal the user's window.
- `--wait` — block until the turn finishes. Omit it to fire and forget, then
  poll with `status` or block later with `wait`.

`new` and `spawn` check that the agent applied every `--mode`, `--model` and
`--effort` given. If one did not take (a typo, a level the model does not
offer), they kill the session and exit `1` with a message naming each value
that differed and what the agent offers instead — rather than letting the
agent run on its default:

```
Agent did not apply --effort bogus (has default; offers default, low, medium, high, xhigh, max)
agent-shell-ctl: killed session Claude Agent @ repo
```

Prefer `--prompt-file` for anything longer than a sentence; `--prompt` is fine
for short text.

Separating the steps is also fine — `worktree-new` prints a path, `new` prints a
session name, `send` delivers a prompt:

```bash
WT=$("$CTL" worktree-new --repo /path/to/repo --name my-feature)
S=$("$CTL" new --agent codex --dir "$WT")
"$CTL" send --session "$S" --prompt-file /tmp/task.md --wait
```

## Talking to a running session

```bash
"$CTL" send --session bold-turing --prompt 'Also update the README.' --wait
```

`send` adapts to what the session is doing:

- idle → submits immediately (prints `sent`)
- busy → queues the prompt, delivered when the current turn ends (prints `queued`)
- busy with `--steer` → injects mid-turn for agents that support steering
  (prints `steered`; errors if the agent does not support it)

## Reading output

```bash
"$CTL" output --session bold-turing            # agent's last message (default)
"$CTL" output --session bold-turing --tail 80  # last 80 transcript lines
"$CTL" output --session bold-turing --all      # whole transcript
```

`--last` returns the agent's final message of the most recent completed turn,
exactly as the agent wrote it (markdown, not the rendered buffer). Text the agent
wrote before its last tool call is dropped, so this is the answer rather than its
"let me check…" preamble. While a turn is running, it is still the previous
turn's message.

A session the wrapper has not seen finish a turn yet (one started by hand in
Emacs, until its next turn ends) has no captured message; `--last` then falls
back to the rendered text of the latest response.

`--tail`/`--all` return rendered buffer text, including the shell's own prompts
and markers like `<shell-maker-end-of-prompt>`; ignore those.

## Waiting

`--wait` on `spawn`/`send` blocks until that specific prompt's turn finishes.

To wait later instead, pass the turn number `send` printed (`sent<TAB>N`) back as
`--since`, which is exact:

```bash
R=$("$CTL" send --session bold-turing --prompt 'Refactor the parser.')
"$CTL" wait --session bold-turing --since "$(printf '%s' "$R" | cut -f2)" --timeout 900
```

Bare `wait --session S` (no `--since`) just waits out whatever is in flight, and
returns immediately if the session is already `ready`. Right after a `send`
there is a brief window where the session still reads `ready`, so prefer
`--since` when you have it.

Both forms exit with:

- `0` — the turn finished
- `2` — the session is `blocked` on a permission dialog
- `3` — the timeout elapsed (the agent is still working)

On `2`, **stop and tell the user**: a permission prompt is open in their Emacs
and only they can answer it. Do not try to approve it. Suggest re-spawning with
a more permissive `--mode` if this keeps happening.

On `3`, report that it is still running and offer to keep waiting — do not
assume failure.

## Cleanup

```bash
"$CTL" kill --session bold-turing
"$CTL" worktree-remove --worktree /path/to/worktree [--force] [--delete-branch]
```

`kill` kills the shell buffer, which shuts down the ACP client and the agent
process.

`worktree-remove` refuses to touch the main worktree, and without `--force`
refuses a worktree with uncommitted or untracked changes — it checks this
*before* killing anything, so a refused removal leaves the sessions running.
Only once the removal will succeed does it kill every session whose working
directory is inside the worktree, then run `git worktree remove`.

When it refuses, **surface that to the user and ask** rather than reaching for
`--force`, which discards the agent's work. `--delete-branch` additionally
deletes the worktree's branch.

Deleting a worktree destroys work. Confirm with the user before removing one you
did not create in this conversation.

## Notes

- The worktree starts at the repo's current `HEAD` unless `--base` says
  otherwise. If the user wants the agent working from a specific branch, pass it.
- A new session takes a few seconds to initialize; `new` and `spawn` already wait
  for this, so a prompt is never sent into an unready session.
- Buffer names collide when two worktrees share a basename — Emacs disambiguates
  with `<2>`, so use the full name from `list` in that case.
- Sessions the user started by hand in Emacs are visible to `list` and usable
  with `send`/`output`/`kill` too. Be careful: `kill` on one of those discards a
  conversation the user may still want.
