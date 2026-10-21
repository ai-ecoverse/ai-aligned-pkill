#!/bin/bash
#
# test.sh - behavioural tests for the ai-aligned-pkill shim.
#
# Every process signalled here is a throwaway `sleep` this script started,
# tagged with a marker unique to this run. Runs against a throwaway state dir
# and bin dir; never touches the user's real ~/.ai-aligned-pkill.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/executable_ai-aligned-pkill"

TMP="$(mktemp -d -t aap-test)"
SPAWNED=()
cleanup() {
    local p
    for p in "${SPAWNED[@]}"; do /bin/kill -9 "$p" 2>/dev/null; done
    [ -r "$TMP/q.pid" ] && /bin/kill -9 "$(cat "$TMP/q.pid")" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

export AI_ALIGNED_PKILL_HOME="$TMP/state"
export AI_ALIGNED_PKILL_HARNESSES="pi claude codex aapk-me aapk-other"
export AI_ALIGNED_PKILL_PROTECT="$TMP/Apps/"
export PATH="$TMP/bin:$PATH"
# Force agent detection on: these tests exercise the managed path.
export CLAUDECODE=1
unset AMI_PASSTHROUGH AI_ALIGNED_PKILL_DISABLE AI_ALIGNED_PKILL_MAX

mkdir -p "$TMP/bin" "$TMP/Apps/Fake.app/Contents/MacOS"
install -m 0755 "$SHIM" "$TMP/bin/ai-aligned-pkill"
ln -sf ai-aligned-pkill "$TMP/bin/pkill"
ln -sf ai-aligned-pkill "$TMP/bin/pgrep"
ln -sf /bin/sleep "$TMP/Apps/Fake.app/Contents/MacOS/Fake"

PASS=0; FAIL=0
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS+1)); }
no()   { printf '%s✗%s %s\n'   "$RED" "$NC" "$1"; printf '    %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
skip() { printf '%s-%s %s (skipped: %s)\n' "$YELLOW" "$NC" "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$3', got '$2'"; fi; }

alive() { /bin/kill -0 "$1" 2>/dev/null; }
settle() { sleep 0.4; }
M="aapk-$$"
n=0
# A unique duration doubles as the marker visible in `ps`: "sleep 4242001".
# Sets $MARK (not via $(...), whose subshell would lose the counter).
mark() { n=$((n + 1)); MARK=$(printf '42%03d%03d' "$(( $$ % 1000 ))" "$n"); }
# Sets $LAST; must not run in $(...), which would wait for the child's stdout.
spawn() { sleep "$1" >/dev/null 2>&1 & LAST=$!; SPAWNED+=("$LAST"); }
# The orphan's PID comes back on stdout from inside the subshell.
spawn_orphan() { ( "$@" >/dev/null 2>&1 & echo $! ); }
pid_of() { /usr/bin/pgrep -f "^$1\$" | head -1; }

if [ "$(uname -s)" != "Darwin" ]; then
    skip "all behavioural tests" "not macOS"
    echo "0 passed, 0 failed"; exit 0
fi

# --------------------------------------------------------------- humans

out=$(AMI_PASSTHROUGH=true pgrep "$M-a" "$M-b"; echo "rc=$?")
check "humans: untouched BSD pgrep accepts two patterns" "${out##*rc=}" "1"

out=$(AI_ALIGNED_PKILL_DISABLE=true pgrep "$M-a" "$M-b"; echo "rc=$?")
check "AI_ALIGNED_PKILL_DISABLE passes through" "${out##*rc=}" "1"

# --------------------------------------------------------------- GNU parsing

pgrep "$M-a" "$M-b" 2>"$TMP/err"; rc=$?
check "agents: two patterns are a usage error (GNU)" "$rc" "2"
grep -q "only one pattern" "$TMP/err" && ok "  ...and the error says why" \
                                     || no "  ...and the error says why" "$(cat "$TMP/err")"

mark; s=$MARK; spawn "$s"; p=$LAST; settle
out=$(pgrep -f "sleep $s" -n 2>/dev/null)
check "pgrep -f PATTERN -n: trailing -n is an option, not a pattern" "$out" "$p"
pgrep -f "sleep $s" -n 2>&1 >/dev/null | grep -q "GNU-style" \
    && ok "  ...and a note says options were read GNU-style" \
    || no "  ...and a note says options were read GNU-style"

out=$(pgrep -f "zzz-$M-nothing" -n; echo "rc=$?")
check "pgrep -f NOMATCH -n finds nothing (macOS would match every '-n')" "$out" "rc=1"

out=$(pgrep -a -f "sleep $s")
check "pgrep -a lists the full command line" "$out" "$p sleep $s"
out=$(pgrep -l -f "sleep $s")
check "pgrep -l lists the name" "$out" "$p sleep"
out=$(pgrep -c -f "sleep $s")
check "pgrep -c counts" "$out" "1"

mark; s2=$MARK; spawn "$s2"; p2=$LAST; settle
out=$(pgrep -d, -f "sleep ($s|$s2)")
check "pgrep -d joins with the delimiter" "$out" "$p,$p2"
out=$(pgrep --oldest --full "sleep ($s|$s2)")
check "long options (--oldest --full)" "$out" "$p"

pgrep --session 1 x 2>/dev/null; check "unsupported procps options are a usage error" "$?" "2"

# --------------------------------------------------------------- pkill

pkill -f "sleep $s" -n -e > "$TMP/out" 2>/dev/null; rc=$?
wait "$p" 2>/dev/null
check "pkill -f PATTERN -n kills the match" "$rc" "0"
alive "$p" && no "  ...which is gone" "pid $p still alive" || ok "  ...which is gone"
check "  ...and -e echoes it" "$(cat "$TMP/out")" "sleep killed (pid $p)"
alive "$p2" && ok "  ...and nothing else" || no "  ...and nothing else" "pid $p2 died too"

pkill -f "sleep $s2" -KILL 2>/dev/null; wait "$p2" 2>/dev/null; st=$?
check "pkill PATTERN -KILL: signal after the pattern" "$st" "137"

mark; s=$MARK; spawn "$s"; p=$LAST; settle
# Not INT: non-interactive shells start background jobs with SIGINT ignored.
pkill --signal=USR1 -f "sleep $s"; wait "$p" 2>/dev/null; st=$?
check "pkill --signal=USR1" "$st" "158"

mark; s=$MARK; spawn "$s"; p=$LAST; settle
pkill -hup -f "sleep $s"; wait "$p" 2>/dev/null; st=$?
check "pkill -hup (lowercase signal, GNU)" "$st" "129"

out=$(pkill -f "zzz-$M-nothing"; echo "rc=$?")
check "pkill with no match returns 1" "$out" "rc=1"

mark; s=$MARK; spawn "$s"; p=$LAST; settle
pkill -v -f "sleep $s" 2>/dev/null; rc=$?
check "pkill -v is refused" "$rc" "3"
alive "$p" && ok "  ...and nothing was signalled" || no "  ...and nothing was signalled"
/bin/kill "$p" 2>/dev/null

# The incident: the command's own ancestry must survive a pattern it contains.
out=$(bash -c "pkill -f 'ancestor-$M'; echo survived" 2>/dev/null)
check "pkill never signals its own ancestors" "$out" "survived"

# --------------------------------------------------------------- blast radius

mark; s=$MARK; pids=()
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do spawn "${s}0"; pids+=("$LAST"); done; settle
pkill -f "sleep ${s}0" 2>"$TMP/err"; rc=$?
check "pkill matching 12 > cap 10 is refused" "$rc" "3"
grep -q "matched 12 processes (limit 10)" "$TMP/err" && ok "  ...with the reason" \
                                                     || no "  ...with the reason" "$(head -3 "$TMP/err")"
alive "${pids[0]}" && alive "${pids[11]}" && ok "  ...and nothing was signalled" \
                                          || no "  ...and nothing was signalled"
AI_ALIGNED_PKILL_MAX=20 pkill -f "sleep ${s}0"; rc=$?
check "AI_ALIGNED_PKILL_MAX raises the cap" "$rc" "0"
for q in "${pids[@]}"; do wait "$q" 2>/dev/null; done
alive "${pids[5]}" && no "  ...and they are gone" || ok "  ...and they are gone"

# --------------------------------------------------------------- vetting
#
# Run pkill from inside a fake harness "aapk-me", so the session boundary is
# that process; targets elsewhere play the parts of everything else.

in_me() { bash -c "exec -a aapk-me bash -c \"\$1; exit \\\$?\"" _ "$1"; }

# Ours: started inside our own harness, backgrounded in an earlier "tool call".
mark; s=$MARK
in_me "sleep $s >/dev/null 2>&1 & echo \$! > $TMP/ours.pid; pkill -f 'sleep $s'; echo \$? > $TMP/ours.rc"
check "allows: a process this agent session started" "$(cat "$TMP/ours.rc")" "0"

# Another agent's: a sibling harness's child.
mark; s=$MARK
bash -c "exec -a aapk-other bash -c 'sleep $s; :'" >/dev/null 2>&1 & SPAWNED+=($!); settle
p=$(pid_of "sleep $s"); SPAWNED+=("$p")
in_me "pkill -f 'sleep $s' 2>$TMP/err; echo \$? > $TMP/rc"
check "refuses: another agent session's process" "$(cat "$TMP/rc")" "3"
grep -q "another agent session: aapk-other" "$TMP/err" && ok "  ...naming the agent" \
                                                       || no "  ...naming the agent" "$(cat "$TMP/err")"
alive "$p" && ok "  ...and it survives" || no "  ...and it survives"

# Orphan: a `cmd &` server that outlived the tool shell that started it.
mark; s=$MARK
p=$(spawn_orphan sleep "$s"); SPAWNED+=("$p"); settle
in_me "pkill -f 'sleep $s' 2>$TMP/err; echo \$? > $TMP/rc"
check "allows: an orphan reparented to launchd" "$(cat "$TMP/rc")" "0"

# launchd job: a child of launchd leading its own process group.
mark; s=$MARK
p=$(spawn_orphan python3 -c "import os; os.setpgid(0, 0); os.execvp('sleep', ['sleep', '$s'])")
SPAWNED+=("$p"); settle
in_me "pkill -f 'sleep $s' 2>$TMP/err; echo \$? > $TMP/rc"
check "refuses: a launchd job (own process group)" "$(cat "$TMP/rc")" "3"
alive "$p" && ok "  ...and it survives" || no "  ...and it survives"

# Terminal session: a login shell (argv[0] starts with '-').
mark; s=$MARK
p=$(spawn_orphan bash -c "exec -a -aapk-shell sleep $s"); SPAWNED+=("$p"); settle
in_me "pkill -f 'aapk-shell $s' 2>$TMP/err; echo \$? > $TMP/rc"
check "refuses: a login shell" "$(cat "$TMP/rc")" "3"
grep -q "terminal session" "$TMP/err" && ok "  ...as a terminal session" \
                                      || no "  ...as a terminal session" "$(cat "$TMP/err")"

# App bundle: anything under a protected prefix (here a fake /Applications).
mark; s=$MARK
p=$(spawn_orphan "$TMP/Apps/Fake.app/Contents/MacOS/Fake" "$s"); SPAWNED+=("$p"); settle
in_me "pkill -f 'Fake $s' 2>$TMP/err; echo \$? > $TMP/rc"
check "refuses: an app bundle's process" "$(cat "$TMP/rc")" "3"
grep -q "is part of Fake.app" "$TMP/err" && ok "  ...naming the app" \
                                         || no "  ...naming the app" "$(cat "$TMP/err")"
alive "$p" && ok "  ...and it survives" || no "  ...and it survives"

# One refused match refuses the lot: our own sleep survives alongside the app.
mark; s=$MARK
p=$(spawn_orphan "$TMP/Apps/Fake.app/Contents/MacOS/Fake" "${s}1"); SPAWNED+=("$p"); settle
in_me "sleep ${s}2 >/dev/null 2>&1 & echo \$! > $TMP/q.pid; sleep 0.3; pkill -f '${s}[12]' 2>/dev/null; echo \$? > $TMP/rc"
q=$(cat "$TMP/q.pid")
check "refuses all-or-nothing when any match is protected" "$(cat "$TMP/rc")" "3"
alive "$q" && ok "  ...so this session's own match survives too" || no "  ...so this session's own match survives too"

# --------------------------------------------------------------- cli

ai-aligned-pkill check -f "sleep $s" -- 2>&1 >/dev/null | grep -q "REFUSE\|ok" \
    && ok "ai-aligned-pkill check reports verdicts" || no "ai-aligned-pkill check reports verdicts"
alive "$q" && ok "  ...without signalling" || no "  ...without signalling"
ai-aligned-pkill log 50 | grep -q "refused" && ok "decisions are logged" || no "decisions are logged"
ai-aligned-pkill doctor | grep "detected as" | grep -vq ": none" && ok "doctor reports the agent" \
                                                                 || no "doctor reports the agent"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
