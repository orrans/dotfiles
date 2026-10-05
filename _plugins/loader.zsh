#!/usr/bin/env zsh

load_plugins() {
  setopt +o nomatch
  # local/ is a stow symlink, which ** does not descend into. It also runs
  # compinit, which fzf-tab needs before it loads — so it goes first.
  local -aU plugin_files=(
    ~/.local/share/zsh/plugins/local/*.plugin.zsh(N)
    ~/.local/share/zsh/plugins/**/*.plugin.zsh(N)
  )
  for plugin in $plugin_files; do
    [[ -e "$plugin" && "$plugin" != *.disabled.zsh ]] && source "$plugin"
  done
  source ~/.local/share/zsh/plugins/powerlevel10k/powerlevel10k.zsh-theme
  setopt -o nomatch
}

load_plugins
