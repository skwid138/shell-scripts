#!/usr/bin/env zsh
# init.zsh — forwarding shim. Sources the three-barrel init in tier order.
#
# DEPRECATED for direct sourcing; ~/.zshenv, ~/.zprofile, and ~/.zshrc reach
# the barrels directly post-Phase-4. This shim is kept indefinitely so any
# external consumer that historically did `source ~/code/scripts/shell/init.sh`
# (now renamed to init.zsh) still works without surprise.
#
# Real file (not a symlink) so the deprecation comment is visible to
# `cat`/`grep` and the rename shows up in `git blame`.
source "${0:A:h}/init_env.zsh"
source "${0:A:h}/init_profile.zsh"
source "${0:A:h}/init_rc.zsh"
