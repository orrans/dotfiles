#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# dotfiles installer
# Installs stow + sofmani, symlinks configs, and runs sofmani to set up the rest.
# Safe to run multiple times (idempotent).
#
# Supports macOS, Linux, WSL and native Windows (run it from Git Bash).
# Usage: ./install.sh [-y|--yes]
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$HOME/.dotfiles"
DOTFILES_REPO="git@github.com:chenasraf/dotfiles.git"
SOFMANI_VERSION="latest"
STOW_VERSION="2.4.1"
LOG_FILE="${TMPDIR:-/tmp}/dotfiles-install-$(date +%Y%m%d-%H%M%S).log"
ASSUME_YES=0
# Windows only: WSL distro/user to also install into (see setup_wsl_windows)
WSL_DISTRO="${WSL_DISTRO:-}"
WSL_USER="${WSL_USER:-$(echo "${USER:-${USERNAME:-user}}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"

for arg in "$@"; do
  case "$arg" in
  -y | --yes) ASSUME_YES=1 ;;
  -h | --help)
    echo "Usage: $0 [-y|--yes]"
    exit 0
    ;;
  esac
done

# Windows-only tools installed with winget (brew equivalents live in sofmani.yml)
WINGET_PACKAGES=(
  Neovim.Neovim
  JesseDuffield.lazygit
  BurntSushi.ripgrep.MSVC
  junegunn.fzf
  sharkdp.fd
  sharkdp.bat
  jqlang.jq
  dandavison.delta
  direnv.direnv
  MikeFarah.yq
  pnpm.pnpm
  zig.zig # C compiler for nvim-treesitter parsers
)

# --- Colors & logging --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log() { printf "${BLUE}[info]${RESET} %s\n" "$*" | tee -a "$LOG_FILE"; }
ok() { printf "${GREEN}[ok]${RESET} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[warn]${RESET} %s\n" "$*" | tee -a "$LOG_FILE"; }
err() { printf "${RED}[error]${RESET} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }

run() {
  log "$ $*"
  if "$@" >>"$LOG_FILE" 2>&1; then
    return 0
  else
    local rc=$?
    err "Command failed (exit $rc): $*"
    err "See log for details: $LOG_FILE"
    return $rc
  fi
}

# ask "Question" [y|n default] -> 0 = yes. With --yes the default answer is used.
ask() {
  local prompt="$1" default="${2:-y}" answer=""
  if [[ "$ASSUME_YES" == 1 ]]; then
    [[ "$default" == y ]]
    return
  fi
  if [[ "$default" == y ]]; then
    printf "\n${BOLD}%s [Y/n]${RESET} " "$prompt"
  else
    printf "\n${BOLD}%s [y/N]${RESET} " "$prompt"
  fi
  read -r answer || true
  if [[ "$default" == y ]]; then
    [[ "$answer" != [nN]* ]]
  else
    [[ "$answer" == [yY]* ]]
  fi
}

# --- Platform detection -------------------------------------------------------

detect_platform() {
  case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      PLATFORM="wsl"
    else
      PLATFORM="linux"
    fi
    ;;
  MINGW* | MSYS* | CYGWIN*) PLATFORM="windows" ;;
  *)
    err "Unsupported OS: $(uname -s)"
    exit 1
    ;;
  esac
  log "Detected platform: $PLATFORM"
}

# --- Helpers ------------------------------------------------------------------

has() { command -v "$1" >/dev/null 2>&1; }

# --- Windows helpers ------------------------------------------------------------
# On Windows this script runs inside Git Bash (MSYS). "/" is the Git for Windows
# install dir (e.g. C:/Program Files/Git); zsh and tmux get installed into it.

win_msys_root() { cygpath -m / | sed 's:/*$::'; }

# Run a bash script with administrator rights (one UAC prompt), wait for it.
run_elevated_bash() {
  local script="$1" bash_win script_win
  bash_win="$(cygpath -w /usr/bin/bash.exe)"
  script_win="$(cygpath -w "$script")"
  log "Requesting administrator rights (UAC prompt) to write into $(win_msys_root)..."
  powershell.exe -NoProfile -Command \
    "\$p = Start-Process -FilePath '$bash_win' -ArgumentList '\"$script_win\"' -Verb RunAs -Wait -PassThru; exit \$p.ExitCode"
}

# Extract a zstd tarball (Git Bash ships no zstd; use what is available).
extract_zst_tar() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  if has zstd; then
    zstd -dc "$archive" | tar -x -C "$dest"
  elif has 7z; then
    7z x -so "$archive" | tar -x -C "$dest"
  elif [[ -x "/c/Program Files/7-Zip/7z.exe" ]]; then
    "/c/Program Files/7-Zip/7z.exe" x -so "$archive" | tar -x -C "$dest"
  elif python -c "import compression.zstd" >/dev/null 2>&1; then
    python -c "import tarfile,sys; tarfile.open(sys.argv[1],'r:zst').extractall(sys.argv[2], filter='fully_trusted')" \
      "$(cygpath -w "$archive")" "$(cygpath -w "$dest")"
  else
    err "Need zstd, 7-Zip or Python >= 3.14 to extract $archive"
    return 1
  fi
}

# URL of the latest MSYS2 package for a name (e.g. zsh, tmux, libevent).
msys2_pkg_url() {
  local name="$1" base="https://repo.msys2.org/msys/x86_64" file
  file="$(curl -fsSL "$base/" | grep -oE "href=\"$name-[0-9][^\"]*-x86_64\.pkg\.tar\.zst\"" | sed 's/^href="//;s/"$//' | sort -V | tail -1)"
  [[ -n "$file" ]] || {
    err "Could not find MSYS2 package: $name"
    return 1
  }
  echo "$base/$file"
}

# Install MSYS2 packages into the Git for Windows tree (Git Bash has no zsh/tmux).
install_msys2_packages() {
  local pkgs=("$@") tmp stage p url
  tmp="$(mktemp -d)"
  stage="$tmp/stage"
  mkdir -p "$stage"
  for p in "${pkgs[@]}"; do
    url="$(msys2_pkg_url "$p")"
    log "Downloading $url"
    curl -fsSL -o "$tmp/$p.pkg.tar.zst" "$url"
    extract_zst_tar "$tmp/$p.pkg.tar.zst" "$stage"
  done
  rm -f "$stage"/.BUILDINFO "$stage"/.INSTALL "$stage"/.MTREE "$stage"/.PKGINFO

  printf '#!/usr/bin/env bash\nset -e\ncp -a "%s/." /\n' "$stage" >"$tmp/apply.sh"
  chmod +x "$tmp/apply.sh"

  if touch /.__dotfiles_wtest 2>/dev/null; then
    rm -f /.__dotfiles_wtest
    run bash "$tmp/apply.sh"
  else
    run_elevated_bash "$tmp/apply.sh"
  fi
  rm -rf "$tmp"
}

install_stow_windows() {
  local stow_home="$HOME/.local/share/stow" tmp src wrapper
  tmp="$(mktemp -d)"
  log "Downloading GNU Stow $STOW_VERSION (runs on Git Bash's perl)..."
  curl -fsSL "https://ftp.gnu.org/gnu/stow/stow-$STOW_VERSION.tar.gz" | tar -xz -C "$tmp"
  src="$tmp/stow-$STOW_VERSION"
  mkdir -p "$stow_home/bin" "$stow_home/lib/Stow" "$HOME/.local/bin"
  sed -e "s|@PERL@|/usr/bin/perl|" -e "s|@VERSION@|$STOW_VERSION|g" \
    -e "s|@USE_LIB_PMDIR@|use lib \"$stow_home/lib\";|" "$src/bin/stow.in" >"$stow_home/bin/stow"
  sed -e "s|@VERSION@|$STOW_VERSION|g" "$src/lib/Stow.pm.in" >"$stow_home/lib/Stow.pm"
  sed -e "s|@VERSION@|$STOW_VERSION|g" "$src/lib/Stow/Util.pm.in" >"$stow_home/lib/Stow/Util.pm"
  # Wrapper: force real Windows symlinks (MSYS default would copy files instead)
  wrapper="$HOME/.local/bin/stow"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"' \
    'exec perl "$HOME/.local/share/stow/bin/stow" "$@"' >"$wrapper"
  chmod +x "$wrapper" "$stow_home/bin/stow"
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
}

ensure_windows_tools() {
  if ! has winget; then
    warn "winget not found; skipping Windows tool installs"
    return
  fi
  local id
  for id in "${WINGET_PACKAGES[@]}"; do
    if winget list --id "$id" -e --accept-source-agreements >/dev/null 2>&1; then
      ok "$id already installed"
      continue
    fi
    log "winget install $id"
    if ! winget install -e --id "$id" --accept-package-agreements --accept-source-agreements --silent --disable-interactivity >>"$LOG_FILE" 2>&1; then
      warn "winget failed for $id (see $LOG_FILE)"
    fi
  done
}

install_atuin_windows() {
  if has atuin; then
    ok "atuin already installed"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading atuin..."
  curl -fsSL -o "$tmp/atuin.zip" "https://github.com/atuinsh/atuin/releases/latest/download/atuin-x86_64-pc-windows-msvc.zip"
  unzip -q -o "$tmp/atuin.zip" -d "$tmp/atuin"
  mkdir -p "$HOME/.local/bin"
  find "$tmp/atuin" -name 'atuin.exe' -exec mv -f {} "$HOME/.local/bin/atuin.exe" \;
  rm -rf "$tmp"
  ok "atuin installed"
}

install_nerd_font_windows() {
  local font_dir
  font_dir="$(cygpath -u "$LOCALAPPDATA")/Microsoft/Windows/Fonts"
  if [[ -f "$font_dir/FiraCodeNerdFontMono-Regular.ttf" || -f /c/Windows/Fonts/FiraCodeNerdFontMono-Regular.ttf ]]; then
    ok "FiraCode Nerd Font already installed"
    return
  fi
  local tmp f name
  tmp="$(mktemp -d)"
  log "Downloading FiraCode Nerd Font..."
  curl -fsSL -o "$tmp/FiraCode.zip" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip"
  unzip -q -o "$tmp/FiraCode.zip" 'FiraCodeNerdFontMono-*.ttf' -d "$tmp/fonts"
  mkdir -p "$font_dir"
  for f in "$tmp/fonts"/*.ttf; do
    name="$(basename "$f" .ttf)"
    cp -f "$f" "$font_dir/"
    # per-user font registration (no admin needed)
    MSYS2_ARG_CONV_EXCL='*' reg add 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts' \
      /v "$name (TrueType)" /t REG_SZ /d "$(cygpath -w "$font_dir/$name.ttf")" /f >>"$LOG_FILE" 2>&1
  done
  rm -rf "$tmp"
  ok "FiraCode Nerd Font installed (per-user)"
}

# Alacritty on Windows reads %APPDATA%\alacritty\alacritty.toml. Write a small
# entry file there that imports the repo's windows.toml (which pulls in
# shared.toml) and sets the shell. With a WSL distro the import points at the
# dotfiles inside WSL, since that is where the shell runs and where the configs
# are edited; otherwise at this checkout.
configure_alacritty_windows() {
  local script distro cfg_dir wsl_home
  script="$DOTFILES_DIR/.config/alacritty/install-windows.sh"
  distro="$(wsl_distro)"
  if [[ -n "$distro" ]]; then
    # The configs are edited inside WSL, so point the entry file at that copy and
    # let the script run there — it resolves \\wsl.localhost paths on its own.
    wsl_home="$(wsl.exe -d "$distro" -- wslpath -w '~' 2>/dev/null | tr -d '\r\0' | tr '\\' '/')"
    if [[ -n "$wsl_home" && -d "$wsl_home/.dotfiles/.config/alacritty" ]]; then
      if wsl.exe -d "$distro" -- sh -c 'sh "$HOME/.dotfiles/.config/alacritty/install-windows.sh"'; then
        ok "Alacritty config written from WSL ($distro)"
        return
      fi
      warn "WSL generator failed; falling back to this checkout"
    fi
  fi
  sh "$script"
  cfg_dir="$(cygpath -m "$DOTFILES_DIR")/.config/alacritty"
  ok "Alacritty config written (imports $cfg_dir, shell: ${distro:-native zsh})"
}

# --- WSL (driven from Windows) --------------------------------------------------

# WSL distro to set up: $WSL_DISTRO, else "Ubuntu", else the first non-docker distro.
wsl_distro() {
  if [[ -n "${WSL_DISTRO:-}" ]]; then
    echo "$WSL_DISTRO"
    return
  fi
  has wsl.exe || return 0
  local list
  list="$(wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -v '^$' | grep -vi '^docker-desktop' || true)"
  if grep -qx 'Ubuntu' <<<"$list"; then
    echo "Ubuntu"
  else
    head -1 <<<"$list"
  fi
}

# Create a sudo user in the distro (Homebrew refuses root), sync this repo into
# its home and run this same installer inside WSL.
setup_wsl_windows() {
  local distro
  distro="$(wsl_distro)"
  if [[ -z "$distro" ]]; then
    log "No WSL distro found; skipping WSL setup"
    return
  fi
  if ! ask "Also install the dotfiles inside WSL distro '$distro' (as user '$WSL_USER')?"; then
    warn "Skipped WSL setup"
    return
  fi

  # NOTE: wsl.exe re-parses its command line through the distro's shell, so
  # scripts are fed via stdin instead of "bash -c" to keep quoting/expansion sane.
  local tmp
  tmp="$(mktemp -d)"

  log "WSL ($distro): ensuring user '$WSL_USER' with passwordless sudo..."
  cat >"$tmp/wsl-root.sh" <<EOF
set -e
id -u '$WSL_USER' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$WSL_USER'
echo '$WSL_USER ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/'$WSL_USER'
chmod 440 /etc/sudoers.d/'$WSL_USER'
if ! grep -q '^default=' /etc/wsl.conf 2>/dev/null; then
  printf '\n[user]\ndefault=$WSL_USER\n' >>/etc/wsl.conf
fi
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync git curl >/dev/null
EOF
  wsl.exe -d "$distro" -u root -- bash -s <"$tmp/wsl-root.sh" >>"$LOG_FILE" 2>&1
  wsl.exe --set-default "$distro" >/dev/null 2>&1 || true

  log "WSL ($distro): syncing dotfiles into ~/.dotfiles (a copy; /mnt/c is too slow for a shell)"
  local src_win
  src_win="$(cygpath -w "$SCRIPT_DIR")"
  cat >"$tmp/wsl-sync.sh" <<EOF
set -e
src="\$(wslpath -u '$src_win')"
[ -f "\$src/install.sh" ] || { echo "dotfiles not found at \$src"; exit 1; }
mkdir -p ~/.dotfiles
rsync -a --exclude '/node_modules' "\$src/" ~/.dotfiles/
git -C ~/.dotfiles config core.filemode false
git -C ~/.dotfiles config core.autocrlf false
EOF
  wsl.exe -d "$distro" -u "$WSL_USER" -- bash -s <"$tmp/wsl-sync.sh" >>"$LOG_FILE" 2>&1
  rm -rf "$tmp"

  log "WSL ($distro): running install.sh inside WSL (this can take a while)..."
  if wsl.exe -d "$distro" -u "$WSL_USER" -- bash -lc "cd ~/.dotfiles && ./install.sh --yes" 2>&1 | tee -a "$LOG_FILE"; then
    ok "WSL ($distro) setup finished"
  else
    warn "WSL ($distro) install.sh reported errors (see above)"
  fi
}

# nvim/lazygit on Windows look in %LOCALAPPDATA%/%APPDATA% unless XDG_CONFIG_HOME is set.
set_windows_env() {
  local want cur
  want="$(cygpath -w "$HOME/.config")"
  cur="$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME','User')" | tr -d '\r')"
  if [[ "$cur" == "$want" ]]; then
    ok "XDG_CONFIG_HOME already set"
    return
  fi
  log "Setting user env XDG_CONFIG_HOME=$want"
  powershell.exe -NoProfile -Command "[Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME','$want','User')"
  export XDG_CONFIG_HOME="$want"
}

ensure_homebrew() {
  if [[ "$PLATFORM" == "windows" ]]; then
    log "Skipping Homebrew on Windows"
    return
  fi
  # brew may be installed but not on PATH yet (fresh install, non-zsh login shell)
  if ! has brew; then
    for b in /opt/homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
      [[ -x "$b" ]] && eval "$("$b" shellenv)" && break
    done
  fi
  if has brew; then
    ok "Homebrew already installed"
    return
  fi

  log "Installing Homebrew..."
  if [[ "$PLATFORM" == "linux" || "$PLATFORM" == "wsl" ]]; then
    run sudo apt-get update
    run sudo apt-get install -y build-essential procps curl file git
  fi
  if [[ "$ASSUME_YES" == 1 ]]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Add brew to current session PATH
  if [[ "$PLATFORM" == "macos" && -d "/opt/homebrew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
  ok "Homebrew installed"
}

ensure_git() {
  if has git; then
    ok "git already installed"
    return
  fi

  log "Installing git..."
  case "$PLATFORM" in
  macos) run xcode-select --install 2>/dev/null || true ;;
  linux | wsl) run sudo apt-get update && run sudo apt-get install -y git ;;
  windows)
    err "git not found. Install Git for Windows and run this script from Git Bash."
    exit 1
    ;;
  esac
  ok "git installed"
}

ensure_stow() {
  if has stow; then
    ok "GNU Stow already installed"
    return
  fi

  log "Installing GNU Stow..."
  case "$PLATFORM" in
  macos) run brew install stow ;;
  linux | wsl) run sudo apt-get update && run sudo apt-get install -y stow ;;
  windows) install_stow_windows ;;
  esac
  ok "GNU Stow installed"
}

ensure_sofmani() {
  if has sofmani; then
    ok "sofmani already installed"
    return
  fi

  log "Installing sofmani..."
  case "$PLATFORM" in
  macos)
    run brew tap chenasraf/tap
    run brew install sofmani
    ;;
  linux | wsl | windows)
    local os arch tmp url
    os="linux"
    [[ "$PLATFORM" == "windows" ]] && os="windows"
    arch="$(uname -m)"
    case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    esac
    tmp="$(mktemp -d)"
    url="https://github.com/chenasraf/sofmani/releases/latest/download/sofmani-${os}-${arch}.tar.gz"
    log "Downloading sofmani from $url"
    curl -fsSL "$url" | tar -xz -C "$tmp"
    mkdir -p "$HOME/.local/bin"
    if [[ "$os" == "windows" ]]; then
      mv -f "$tmp/sofmani.exe" "$HOME/.local/bin/sofmani.exe"
    else
      mv "$tmp/sofmani" "$HOME/.local/bin/sofmani"
      chmod +x "$HOME/.local/bin/sofmani"
    fi
    rm -rf "$tmp"
    export PATH="$HOME/.local/bin:$PATH"
    ;;
  esac
  ok "sofmani installed"
}

ensure_zsh() {
  if [[ "$PLATFORM" == "windows" ]]; then
    local need=()
    has zsh || need+=(zsh)
    has tmux || need+=(tmux libevent)
    if [[ ${#need[@]} -eq 0 ]]; then
      ok "zsh and tmux already installed"
      return
    fi
    log "Installing ${need[*]} into Git for Windows ($(win_msys_root))..."
    install_msys2_packages "${need[@]}"
    hash -r
    ok "zsh and tmux installed"
    return
  fi

  if has zsh; then
    ok "zsh already installed"
    return
  fi

  log "Installing zsh..."
  case "$PLATFORM" in
  macos) run brew install zsh ;;
  linux | wsl) run sudo apt-get update && run sudo apt-get install -y zsh ;;
  esac
  ok "zsh installed"
}

# --- Clone & stow -------------------------------------------------------------

clone_dotfiles() {
  # Running from a checkout that isn't ~/.dotfiles: link it instead of cloning again
  if [[ ! -e "$DOTFILES_DIR" && -d "$SCRIPT_DIR/.git" && "$SCRIPT_DIR" != "$DOTFILES_DIR" ]]; then
    log "Linking $DOTFILES_DIR -> $SCRIPT_DIR"
    MSYS=winsymlinks:nativestrict ln -s "$SCRIPT_DIR" "$DOTFILES_DIR"
  fi

  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    ok "Dotfiles repo already at $DOTFILES_DIR"
    return
  fi

  if [[ -d "$DOTFILES_DIR" ]]; then
    warn "$DOTFILES_DIR exists but is not a git repo"
    if ! ask "  Overwrite?" n; then
      err "Aborted. Please move/remove $DOTFILES_DIR and re-run."
      exit 1
    fi
    rm -rf "$DOTFILES_DIR"
  fi

  log "Cloning dotfiles..."
  run git clone "$DOTFILES_REPO" --depth 1 "$DOTFILES_DIR"
  ok "Dotfiles cloned"
}

stow_dotfiles() {
  log "Symlinking configs with stow..."
  # Pre-create shared dirs so stow links their children instead of folding the
  # whole directory into the repo (sofmani clones plugins into these).
  mkdir -p "$HOME/.config" "$HOME/.local/bin" "$HOME/.local/share/zsh/plugins"
  cd "$DOTFILES_DIR"
  if stow -R -t ~ . >>"$LOG_FILE" 2>&1; then
    ok "Configs symlinked"
  else
    warn "Stow had conflicts — attempting adopt + restow..."
    run stow --adopt -t ~ .
    run stow -R -t ~ .
    ok "Configs symlinked (adopted existing files)"
  fi
}

# --- Run sofmani --------------------------------------------------------------

run_sofmani() {
  log "Running sofmani to install tools..."
  if ! ask "This will install all configured tools. Continue?"; then
    warn "Skipped sofmani. Run 'sofmani' manually when ready."
    return
  fi
  local cfg="$DOTFILES_DIR/.config/sofmani.yml"
  if [[ "$PLATFORM" == "windows" ]]; then
    # sofmani runs commands through cmd on Windows, which never expands "~":
    # feed it a copy of the config with "~/" replaced by the real home path.
    local home_win expanded
    home_win="$(cygpath -m "$HOME")"
    expanded="$(mktemp --suffix=.yml)"
    sed "s#~/#$home_win/#g" "$cfg" >"$expanded"
    cfg="$(cygpath -w "$expanded")"
  fi
  if sofmani -U "$cfg"; then
    ok "sofmani finished"
  else
    warn "sofmani finished with errors (see output above)"
  fi
}

# --- Set default shell --------------------------------------------------------

set_default_shell() {
  if [[ "$PLATFORM" == "windows" ]]; then
    ok "Windows: login shell unchanged; Alacritty is configured to launch zsh"
    return
  fi

  local current_shell
  current_shell="$(basename "$SHELL")"
  if [[ "$current_shell" == "zsh" ]]; then
    ok "Default shell is already zsh"
    return
  fi

  if ! ask "Change default shell to zsh?"; then
    warn "Skipped shell change"
    return
  fi

  local zsh_path
  zsh_path="$(which zsh)"
  if ! grep -qF "$zsh_path" /etc/shells 2>/dev/null; then
    log "Adding $zsh_path to /etc/shells"
    echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  fi
  if [[ "$(id -u)" -ne 0 ]] && has sudo && sudo -n true 2>/dev/null; then
    run sudo chsh -s "$zsh_path" "$USER" # avoids the password prompt of plain chsh
  else
    run chsh -s "$zsh_path"
  fi
  ok "Default shell set to zsh"
}

# --- Main ---------------------------------------------------------------------

main() {
  printf "${BOLD}dotfiles installer${RESET}\n"
  printf "Log: %s\n\n" "$LOG_FILE"

  detect_platform
  ensure_git
  clone_dotfiles
  ensure_homebrew
  ensure_zsh
  ensure_stow
  stow_dotfiles
  ensure_sofmani
  if [[ "$PLATFORM" == "windows" ]]; then
    ensure_windows_tools
    install_atuin_windows
    install_nerd_font_windows
    configure_alacritty_windows
    set_windows_env
  fi
  run_sofmani
  set_default_shell
  if [[ "$PLATFORM" == "windows" ]]; then
    setup_wsl_windows
  fi

  printf "\n${GREEN}${BOLD}All done!${RESET}\n"
  if [[ "$PLATFORM" == "windows" ]]; then
    printf "Open (or restart) Alacritty to start zsh with your config.\n"
  else
    printf "Start a new zsh session to load your config:\n"
    printf "  ${BOLD}exec zsh -l${RESET}\n"
  fi
}

main "$@"
