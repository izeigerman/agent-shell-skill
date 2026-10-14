# agent-shell-skill

An [agent skill](https://code.claude.com/docs/en/skills) that lets a coding agent
drive [agent-shell](https://github.com/xenodium/agent-shell) sessions inside a
running Emacs, over `emacsclient`.

It can create a git worktree and start a claude/codex/gemini session in it, hand
that session a task, wait for the turn to finish, read the agent's reply as
markdown, send follow-up messages, kill sessions, and remove worktrees — all
while the session stays a normal agent-shell buffer the user can watch and take
over.

## Requirements

- Emacs running with a server (`M-x server-start`) and `agent-shell` loaded
- `emacsclient` on `PATH` (override with `$EMACSCLIENT`)
- `git`, `bash`

## Install

Clone, then symlink the skill into your skills directory:

```sh
git clone https://github.com/izeigerman/agent-shell-skill ~/github/agent-shell-skill
ln -s ~/github/agent-shell-skill/skills/agent-shell ~/.claude/skills/agent-shell
```

The link name must stay `agent-shell` — it has to match the `name` in
`SKILL.md`'s frontmatter.

Optionally put the CLI on `PATH` so the agent (and you) can call it by name
instead of searching for it:

```sh
ln -s ~/github/agent-shell-skill/skills/agent-shell/bin/agent-shell-ctl ~/.local/bin/
```

The script resolves its own symlinks, so it finds `lib/agent-shell-ctl.el`
correctly either way.

## Use directly

The skill is a thin wrapper around one script, usable on its own:

```sh
CTL=skills/agent-shell/bin/agent-shell-ctl

$CTL --help
$CTL agents
$CTL list

$CTL spawn --agent claude-code --repo ~/code/myproject \
  --prompt 'Add a --json flag to the CLI' --mode acceptEdits --wait

$CTL spawn --agent codex --repo ~/code/myproject \
  --prompt 'Fix the flaky test' --model gpt-6-luna --effort low \
  --mode agent-full-access --wait

$CTL config --session <name>
$CTL output --session <name>
$CTL send   --session <name> --prompt 'Also add tests.' --wait
$CTL kill   --session <name>
$CTL worktree-remove --worktree <path> --delete-branch

# Address a session by its ACP id (last field of `list`/`status`), so a
# new session that reuses the buffer name is never the one reached:
$CTL send   --session-id <id> --prompt 'Continue.'
```

## Layout

```
skills/agent-shell/
├── SKILL.md                 instructions loaded by the agent
├── bin/agent-shell-ctl      CLI wrapper; shells out to emacsclient
└── lib/agent-shell-ctl.el   elisp loaded into the running Emacs
```

The elisp does the actual agent-shell work and writes results to a file, so
output never has to be unescaped from `emacsclient --eval`.

## License

GPL-3.0-or-later, matching agent-shell.
