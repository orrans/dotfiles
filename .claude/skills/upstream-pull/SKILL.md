---
name: upstream-pull
description: Pull and merge changes from the fork parent (chenasraf/dotfiles) into this dotfiles fork without regressing the Windows-side config. This skill should be used when the user asks to pull, fetch, sync, or merge from upstream, to update the fork from the parent repo, or to resolve conflicts left by such a pull. It covers merging instead of rebasing, the standing conflict resolutions for this fork, and porting upstream keybinding changes into the Windows Alacritty config.
---

# Pulling from upstream

This repo is a WSL/Windows fork of the macOS dotfiles at `chenasraf/dotfiles`. Pulling the parent's
work means merging a macOS-shaped tree into a Windows-shaped one, so each pull lands the same few
conflicts and one silent regression: upstream changes a keybinding in `alacritty.toml`, that file
serves macOS here, and the Windows binding set keeps the old keystroke.

`references/standing-resolutions.md` records how this fork diverges and therefore how each
recurring conflict resolves — the Alacritty three-file split, the paths this fork deletes, the
`sofmani.yml` block it removes, the machine aliases. Read it before resolving anything, not after.

## Workflow

1. **Confirm the remote.** `git remote -v`. When no `upstream` exists, add the fork parent:

   ```bash
   git remote add upstream git@github.com:chenasraf/dotfiles.git
   git fetch upstream
   ```

2. **Survey what is coming.** `log.showSignature` is `true` here, so pass `--no-show-signature`
   or every line of history comes wrapped in signature output:

   ```bash
   git rev-list --left-right --count upstream/master...master   # behind<TAB>ahead
   git log --oneline --no-show-signature master..upstream/master
   ```

3. **Merge, never rebase.** `pull.rebase` is `true` in this repo, so a bare
   `git pull upstream master` rewrites every local commit and re-resolves the same conflicts once
   per commit. Always:

   ```bash
   git pull --no-rebase upstream master
   ```

   If a rebase has already started, `git rebase --abort` returns the branch untouched, then merge.

4. **Resolve the conflicts** against `references/standing-resolutions.md`. `merge.conflictStyle`
   is `diff3`, so each hunk shows the merge base between `|||||||` and `=======` — use it to tell
   an upstream change apart from a local deletion. `rerere.enabled` is `true`, so some hunks arrive
   pre-resolved from an earlier pull; confirm those results rather than trusting them.

5. **Check the Windows bindings before committing** (see below).

6. **Validate.** There is no test suite. Syntax-check whatever shell files the merge touched, and
   name the reloads the user has to perform for the rest:

   ```bash
   for f in .zshrc exports.zsh aliases.zsh keybindings.zsh dirs.zsh; do zsh -n "$f" || echo "FAIL $f"; done
   ```

   tmux: `tmux source ~/.config/tmux/tmux.conf`. nvim: restart. Alacritty: reload or restart.

7. **Commit the merge** with a title-only message matching the existing merge commits:
   `Merge upstream/master (chenasraf/dotfiles) into master`. Conventional-commit types do not apply
   to merge commits here. Never add a `Co-Authored-By` trailer.

8. **Report what landed in live config** — aliases that shadow binaries, new exports, changed
   bindings, `git config` changes — since every file in this repo is stowed into `$HOME` and takes
   effect on the next reload. Leave pushing to the user unless they ask.

## Never regress the Windows bindings

Upstream has one `alacritty.toml`. This fork splits it into `shared.toml` (platform-neutral),
`alacritty.toml` (macOS entry, Cmd/Opt) and `windows.toml` (Windows entry, Ctrl/Ctrl+Alt), and
upstream has neither of the latter two. An upstream binding change therefore reaches macOS and
stops there.

Run the checker after every pull, before committing:

```bash
.claude/skills/upstream-pull/scripts/check-alacritty-bindings.py --upstream FETCH_HEAD
```

It matches bindings by payload — the `chars` string or `action` — because the same command is
reached through different modifiers per platform, and reports two kinds of drift:

- macOS payloads missing from `windows.toml` and `shared.toml` — a command Windows cannot reach
- upstream payloads missing from every local file — an upstream change nothing carried over

It exits 1 on drift and 0 when the sets agree. `--upstream` defaults to `upstream/master`; pass
`FETCH_HEAD` right after a pull, or an empty value to compare only the local files.

For every payload it flags, port the binding into `windows.toml` under the modifier mapping in that
file's header comment (Cmd → Ctrl, Cmd+Shift → Ctrl+Shift, Opt → Ctrl+Alt, Cmd+Opt+S →
Ctrl+Alt+Q), then re-run the checker. Two mechanics make this fiddly — `chars` escapes are written
as `\uXXXX` text that the Read/Write/Edit tools decode into raw control bytes, and `key` holds a
winit name where `Shift` matches the shifted character. `references/standing-resolutions.md` has
the script pattern for editing those files safely and the key-name rules.

A payload the checker does not flag still deserves a thought when its *meaning* is
platform-specific: a binding that shells out to a macOS-only binary is worth dropping from
`windows.toml` rather than mirroring.
