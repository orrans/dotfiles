# Standing conflict resolutions

How this fork differs from `chenasraf/dotfiles`, and therefore how each recurring conflict
resolves. Verify against the tree before applying any of it — a resolution recorded here is a
default, not a licence to skip reading the conflict.

## Fork topology

| Remote | Repository | Role |
|--------|------------|------|
| `origin` | `git@github.com:orrans/dotfiles.git` | this fork, where local work is pushed |
| `upstream` | `git@github.com:chenasraf/dotfiles.git` | the fork parent, pulled from |

The fork adapts a macOS dotfiles repo to WSL/Windows, so the two sides disagree along one axis
above all others: upstream assumes macOS and Homebrew on `/opt/homebrew`, this side assumes
WSL, Windows-side terminals, and Linuxbrew.

## Merge, never rebase

`pull.rebase` is `true` in this repo, so a bare `git pull upstream master` replays every local
commit onto upstream's tip — dozens of commits, each able to conflict in the same files, and
every local SHA rewritten even though those commits are already on `origin`. Use
`git pull --no-rebase upstream master` and resolve once. If a rebase has already started,
`git rebase --abort` returns the branch untouched.

`rerere.enabled` is `true`, so resolutions recorded in one pull replay automatically in the next.
A conflict that resolves itself silently has been seen before; confirm the replayed result rather
than assuming it.

## Alacritty: the binding split is local

Upstream keeps one `.config/alacritty/alacritty.toml` holding fonts, colors and every binding.
This fork splits it in three, and only the first is a file upstream also has:

| File | Holds | Exists upstream |
|------|-------|-----------------|
| `alacritty.toml` | the macOS entry: `import = ["shared.toml"]` plus Cmd/Opt bindings | yes |
| `shared.toml` | fonts, colors, platform-neutral bindings | no |
| `windows.toml` | the Windows entry: the same commands under Windows modifiers | no |
| `install-windows.sh` | writes `%APPDATA%\alacritty\alacritty.toml`, which imports `windows.toml` from the WSL checkout | no |

Consequences when pulling:

- An upstream binding change lands in `alacritty.toml` and reaches macOS only. Windows keeps the
  old keystroke until the change is ported into `windows.toml` by hand.
- Upstream edits to parts that live in `shared.toml` here arrive in `alacritty.toml` as additions
  that duplicate or contradict the shared file. Move them into `shared.toml` instead of leaving
  two definitions.
- Alacritty on Windows reads nothing under `~/.config`. The generated `%APPDATA%` entry file
  imports `windows.toml` by path, so editing `windows.toml` is enough — no regeneration, just a
  config reload or an Alacritty restart.

### Porting a binding to Windows

The modifier mapping is documented in the header comment of `windows.toml`: Cmd → Ctrl,
Cmd+Shift → Ctrl+Shift, Opt → Ctrl+Alt, Cmd+Opt+S → Ctrl+Alt+Q. Ctrl carries the Cmd bindings
because Windows captures the Windows key and Alt+Shift switches the input language, so
Ctrl+A/D/G/P/S/T/W/Z never reach the shell or nvim.

Two mechanics bite:

- **`chars` escapes.** TOML `chars` values are written as `\uXXXX` text. The Read/Write/Edit
  tools decode those escapes into raw control bytes, which corrupts the file. Apply `windows.toml`
  and `alacritty.toml` edits with a script instead:

  ```bash
  python3 - <<'PY'
  from pathlib import Path
  p = Path(".config/alacritty/windows.toml")
  s = p.read_text()
  old = 'chars = "\\u001b\\u001b gs\\n"'
  new = 'chars = "\\u0002g"'
  assert s.count(old) == 1
  p.write_text(s.replace(old, new))
  PY
  ```

- **winit key names.** `key` holds a winit name (`Enter`, `Backspace`, bare `"1"` rather than
  `Digit1`), and a binding carrying `Shift` matches the *shifted* character: Ctrl+Shift+0 is
  `key = ")"`, Ctrl+Shift+= is `key = "+"`.

`\u0002` is the tmux prefix (Ctrl+B), `\u001b\u001b ` the nvim leader after two escapes, and
`\u0017` a tmux-navigator Ctrl+W. A payload reaching tmux works from any pane; one reaching the
nvim leader works only inside nvim.

## Paths this fork deletes

Upstream carries these; local commits remove them as macOS-only. A modify/delete conflict on any
of them resolves by staying deleted (`git rm`):

- `.config/ghostty/config`, `.config/wezterm/wezterm.lua` — terminals unused here
- `.config/aerospace/aerospace.toml`, `.config/AutoRaise/config` — macOS window managers
- `.config/opencode/opencode.json`, `.config/opencode/themes/transparent.json`
- `.config/tmux_m1.yml`, `.config/tmux_planck.yml` — device configs for machines outside this
  fork's set; `.config/tmux_work.yml` is the one it carries

## Paths only this fork has

A delete/modify conflict in the other direction, or an add/add conflict, usually means upstream
reorganised something these files depend on. Keep the local file and re-point it:

- `.config/alacritty/{shared.toml,windows.toml,install-windows.sh}`
- `.config/atuin/config.toml`, `.config/github-copilot/versions.json`, `.config/tmux_work.yml`
- `.gitattributes`

## `.config/sofmani.yml`

The macOS-only block — `wezterm`, `alacritty`, `ghostty`, `volumehud` and the nerd-font entries —
is removed locally. Upstream keeps editing inside it (gating casks per machine, adding taps), which
lands as a content conflict against the deletion. Resolution: keep the deletion, `git checkout
--ours -- .config/sofmani.yml`, then read the upstream side for anything that is **not** macOS-only
and port only that.

Machine aliases differ too: upstream gates steps on `m1` and `planck`, this fork on `work`. An
upstream `machines:` filter naming an alias this fork does not define has no effect here and does
not need porting.

## Neovim

Upstream removing a plugin file that local commits modified resolves by accepting the removal when
every spec in the local version carries `enabled = false` — the disabling already expressed the
same intent. Check `cmp.lua` for sources naming the removed plugins; upstream leaves dangling
source entries there, and matching upstream exactly is the goal.
