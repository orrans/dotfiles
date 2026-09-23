# Force a native arm64 shell on Apple Silicon; `arch -arm64` doesn't exist on Linux
if-shell "uname -s | grep -qi darwin" 'set-option -g default-command "arch -arm64 /bin/zsh"'
