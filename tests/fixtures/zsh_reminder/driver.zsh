# Test driver for tests/zsh_reminder.bats — not a standalone script.
#
# Drives a real interactive zsh (ZLE active) through zsh/zpty so the
# fn+arrow reminder widgets in shell/rc/zsh_config.zsh can be exercised
# keystroke by keystroke.
#
# Usage: zsh -f driver.zsh <zsh_config.zsh> <workdir> <key>...
#   keys: home (\e[H)  end (\e[F)  x (literal char)  bs (^?)  left (\e[D)
#
# The child shell is isolated: env -i, HOME=ZDOTDIR=<workdir>, and its
# .zshenv unsets GLOBAL_RCS so /etc/zshrc & friends (which rebind keys on
# macOS) are skipped. Its .zshrc sources the config under test, then adds
# stand-ins for what zsh_plugins.zsh loads later in real use:
#   - a user self-insert wrapper (like zsh-autosuggestions), and
#   - a line-pre-redraw hook registered AFTER the config's own hooks (like
#     zsh-syntax-highlighting); it logs one probe record per redraw.
# `zle -M` is shadowed by a function that remembers the last message, so the
# probe can report what the message line currently holds.
#
# Output (stdout): for each key, a line "@<key>" followed by the child's log
# lines produced while handling that key ("wrap" when the self-insert
# stand-in ran, then one "redraw lw=<LASTWIDGET> msg=[<msg>] si=<widget>").
#
# Exit: 0 ok; 2 usage; 3 timeout / child failure; 77 zsh/zpty unavailable.
# Every wait is bounded; the pty child is killed on exit.

zmodload zsh/zpty 2>/dev/null || {
  print -u2 -- "driver: zsh/zpty module unavailable"
  exit 77
}
integer have_zselect=0
zmodload zsh/zselect 2>/dev/null && have_zselect=1

if (($# < 2)); then
  print -u2 -- "usage: driver.zsh <zsh_config.zsh> <workdir> <key>..."
  exit 2
fi

config=$1 work=$2
shift 2
log=$work/probe.log
pty=zr_child
# Per-wait budget, in 20ms ticks (default 500 = 10s). Generous so a loaded
# machine under `make test --jobs N` doesn't produce false timeouts.
integer max_ticks=${ZR_MAX_TICKS:-500}

mkdir -p -- "$work" || exit 3
: >|"$log"

print -r -- 'unsetopt GLOBAL_RCS' >|"$work/.zshenv"
cat >|"$work/.zshrc" <<'RC'
PS1='zr> '
zmodload zsh/zleparameter
autoload -Uz add-zle-hook-widget
typeset -g _zr_msg=''
zle() {
  [[ $1 == -M ]] && _zr_msg=$2
  builtin zle "$@"
}
source "$ZR_CONFIG"
_zr_self_insert() {
  print -r -- wrap >>"$ZR_LOG"
  zle .self-insert
}
zle -N self-insert _zr_self_insert
_zr_later_redraw() {
  print -r -- "redraw lw=$LASTWIDGET msg=[$_zr_msg] si=$widgets[self-insert]" >>"$ZR_LOG"
}
add-zle-hook-widget line-pre-redraw _zr_later_redraw
_zr_ready() { print -r -- ready >>"$ZR_LOG"; }
add-zle-hook-widget line-init _zr_ready
RC

cleanup() { zpty -d $pty 2>/dev/null; }
trap cleanup EXIT INT TERM HUP

zpty $pty env -i HOME="$work" ZDOTDIR="$work" TERM=xterm PATH="$PATH" \
  ZR_LOG="$log" ZR_CONFIG="$config" "${commands[zsh]:-zsh}" -i || exit 3

drain() {
  local junk
  while zpty -rt $pty junk 2>/dev/null; do :; done
}

tick() {
  if ((have_zselect)); then
    zselect -t 2 2>/dev/null
  else
    sleep 0.02
  fi
}

log_lines=()
read_log() { log_lines=("${(@f)$(<"$log")}"); }

# Wait until the log holds at least $1 lines matching pattern $2.
wait_for() {
  local -i want=$1 i
  local pat=$2
  local -a hits
  for ((i = 0; i < max_ticks; i++)); do
    drain
    read_log
    hits=(${(M)log_lines:#$~pat})
    ((${#hits} >= want)) && return 0
    tick
  done
  print -u2 -- "driver: timed out waiting for $want x '$pat'"
  print -u2 -- "driver: log so far:"
  print -u2 -l -- "${log_lines[@]}"
  return 1
}

wait_for 1 'ready' || exit 3
read_log
integer seen=${#log_lines} redraws=0

for key in "$@"; do
  case $key in
    home) bytes=$'\e[H' ;;
    end) bytes=$'\e[F' ;;
    x) bytes=x ;;
    bs) bytes=$'\x7f' ;;
    left) bytes=$'\e[D' ;;
    *)
      print -u2 -- "driver: unknown key '$key'"
      exit 2
      ;;
  esac
  zpty -w -n $pty "$bytes" || exit 3
  # Send one key at a time and wait for its redraw: ZLE skips redisplay
  # while typeahead is pending, so batching keys would hide redraws.
  wait_for $((++redraws)) 'redraw *' || exit 3
  print -r -- "@$key"
  print -rl -- "${(@)log_lines[seen+1,-1]}"
  seen=${#log_lines}
done

exit 0
