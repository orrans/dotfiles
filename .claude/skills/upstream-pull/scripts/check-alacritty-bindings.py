#!/usr/bin/env python3
"""Compare the Alacritty binding sets so a pull from upstream cannot leave Windows behind.

Upstream keeps every binding in a single alacritty.toml. Here that file is split three ways:
shared.toml (platform-neutral), alacritty.toml (the macOS entry, Cmd/Opt) and windows.toml
(the Windows entry, Ctrl/Ctrl+Alt). Bindings are matched by payload -- the `chars` string or
`action` name -- because the same command is reached through different modifiers on each
platform, so keys and mods are expected to differ while payloads are expected to agree.

Reports two kinds of drift:

  macOS payloads absent from the Windows set
      A binding reachable on macOS and not on Windows.

  upstream payloads absent from every local file
      Something upstream added or changed that has not been carried into the split.

Exits 1 when either list is non-empty, 0 when the sets agree.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

BINDING_RE = re.compile(
    r"(?:#[ \t]*(?P<comment>[^\n]*)\n)?"
    r"\[\[keyboard\.bindings\]\]\n"
    r"(?P<body>(?:[a-z_]+ = [^\n]*\n)+)"
)
FIELD_RE = re.compile(r"^(?P<field>[a-z_]+) = (?P<value>.*)$", re.M)


def repo_root():
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(out.stdout.strip())


def parse_bindings(text, origin):
    """Yield (payload, description) for every [[keyboard.bindings]] block in `text`."""
    bindings = []
    for match in BINDING_RE.finditer(text):
        fields = {m["field"]: m["value"].strip('"') for m in FIELD_RE.finditer(match["body"])}
        payload = fields.get("chars") or fields.get("action")
        if payload is None:
            continue
        combo = "+".join(part for part in (fields.get("mods"), fields.get("key")) if part)
        comment = (match["comment"] or "").strip()
        bindings.append((payload, f"{origin}: {combo or '?'}" + (f" -- {comment}" if comment else "")))
    return bindings


def read_rev(rev, path):
    out = subprocess.run(
        ["git", "show", f"{rev}:{path}"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return None
    return out.stdout


def report(title, items):
    if not items:
        print(f"ok   {title}: none")
        return False
    print(f"DRIFT {title}:")
    for payload, description in items:
        print(f'      "{payload}"\n        {description}')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--upstream",
        default="upstream/master",
        help="revision whose .config/alacritty/alacritty.toml holds upstream's single-file binding set "
        "(default: upstream/master; FETCH_HEAD right after a pull). Pass an empty value to skip.",
    )
    args = parser.parse_args()

    root = repo_root()
    config = root / ".config/alacritty"
    local = {
        name: parse_bindings((config / name).read_text(), name)
        for name in ("shared.toml", "alacritty.toml", "windows.toml")
    }

    mac_payloads = {p for p, _ in local["alacritty.toml"]}
    windows_payloads = {p for p, _ in local["windows.toml"]} | {p for p, _ in local["shared.toml"]}
    all_local = mac_payloads | windows_payloads

    upstream = None
    if args.upstream:
        text = read_rev(args.upstream, ".config/alacritty/alacritty.toml")
        if text is None:
            print(f"note  cannot read {args.upstream}:.config/alacritty/alacritty.toml -- skipping that comparison")
        else:
            upstream = parse_bindings(text, args.upstream)

    counts = ", ".join(f"{name} {len(binds)}" for name, binds in local.items())
    if upstream is not None:
        counts += f", {args.upstream} {len(upstream)}"
    print(f"bindings: {counts}\n")

    drift = report(
        "macOS payloads absent from windows.toml and shared.toml",
        [(p, d) for p, d in local["alacritty.toml"] if p not in windows_payloads],
    )

    if upstream is not None:
        drift |= report(
            f"{args.upstream} payloads absent from every local file",
            [(p, d) for p, d in upstream if p not in all_local],
        )

    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
