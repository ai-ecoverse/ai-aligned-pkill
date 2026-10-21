# ai-aligned-pkill

> **AI is going to pkill us all\***
>
> <sub>\* if the simulation happens to run on macOS.</sub>

[![100% Vibe_Coded](https://img.shields.io/badge/100%25-Vibe_Coded-ff69b4?style=for-the-badge&logo=claude&logoColor=white)](https://github.com/ai-ecoverse/vibe-coded-badge-action)

GNU-semantics `pkill` and `pgrep` for coding agents on macOS. It shadows both
on `PATH`, reads the command line the way the Linux tools the agents were
trained on do, and refuses to signal anything outside the agent's own session.
No `CLAUDE.md` section, no `AGENTS.md` rule, no skill. The agent runs the
command it was always going to run.

Humans get `/usr/bin/pkill` and `/usr/bin/pgrep`, untouched.

## Why

One agent, cleaning up a test server it had started, ran:

```sh
pkill -f "node server.mjs" -n 2>/dev/null; ps aux | grep "[s]erver.mjs" | awk '{print $2}' | xargs -r kill
```

On Linux that kills the newest `node server.mjs`. On macOS, within 250 ms, it
took down Google Chrome, every Ghostty tab, the renderer of an Electron app
(blank window, ⌘R to recover), a handful of other agents' Playwright browsers,
and finally the agent's own shell (exit 143).

BSD `getopt` stops at the first operand, and BSD `pkill` accepts several
patterns. So the trailing `-n` was not *newest*: it was a **second pattern**,
and with `-f` it matches any process whose arguments contain `-n` — every
`--no-sandbox` Chromium helper, every `open -n…`, and every terminal tab,
because Ghostty starts shells with `login … /bin/bash --noprofile …`. On the
machine in question, minutes later, `pgrep -f nothing-matches-this -n` still
listed 57 processes.

GNU procps cannot simply be installed instead: it reads `/proc`, and the
Homebrew formula is Linux-only.

## What it does

1. **GNU parsing.** Options may come before or after the pattern, `-SIGNAL`
   may appear anywhere, long options work, and exactly one pattern is allowed —
   a second one is a usage error, as on Linux. The real BSD tool then gets the
   same request with options strictly first.
2. **Vets every match** before signalling, and refuses the whole command if any
   match falls outside the agent's session. Nothing is signalled on refusal.
3. **Caps the blast radius.** A pkill matching more than 10 processes is
   refused, whatever they are.
4. **Signals exactly the PIDs it vetted**, and logs every decision.

`pgrep` gets the parsing and the procps output flags, but no vetting: listing
is harmless.

### Who owns a process

Each match's ancestry is walked until something decides it:

| the match… | verdict |
| --- | --- |
| descends from this agent's harness (`pi`, `claude`, `codex`, …) | signalled |
| is an orphan of launchd, e.g. a `cmd &` server outliving its tool shell | signalled |
| belongs to another agent's harness | refused |
| belongs to a terminal session: `login`, a login shell, `sshd`, `tmux` | refused |
| is, or descends from, an app bundle or system binary (`/Applications`, `/System`, `/usr/libexec`, …) | refused |
| leads its own process group under launchd: a launchd job or service | refused |
| meets this command's ancestry above the harness, e.g. a sibling thread | refused |

Run against the incident's pattern, from an agent:

```
$ ai-aligned-pkill check -f -- '-n'
ai-aligned-pkill: pkill: refused — 12 of the 12 matching processes are outside this agent's session, and the pattern matched 12 processes (limit 10). Nothing was signalled.
  3973    REFUSE is part of bb.app                                    /Applications/bb.app/Contents/Frameworks/bb Helper (Renderer).app/…
  15614   REFUSE belongs to another agent session: claude (pid 45533) /bin/zsh -c source /Users/…/.claude/shell-snapshots/…
  49915   REFUSE belongs to a terminal session: login (pid 49915)     /usr/bin/login -flp trieloff /bin/bash --noprofile --norc -c exec …
  56894   REFUSE is part of LM Studio.app                             /Applications/LM Studio.app/Contents/Frameworks/Electron Framework…
  58761   REFUSE belongs to another agent session: pi (pid 62698)     /opt/homebrew/Cellar/node/…/bin/node --test …
  …
ai-aligned-pkill:   Narrow the match (-x, an anchored -f regex, -P <ppid>, -u $USER), or better,
ai-aligned-pkill:   signal the PID you started:  cmd & pid=$!; ...; kill $pid
ai-aligned-pkill:   Processes this session did not start belong to the user; ask them first.
```

(How many it matches depends on what is running: 57 shortly after the
incident, 12 when this was captured.)

### GNU compatibility

| | |
| --- | --- |
| as procps | `-f -n -o -x -i -v -u -U -G -g -P -t -F -L -A`, `--full --newest --oldest --exact --ignore-case --inverse --euid --uid --group --pgroup --parent --terminal --pidfile --logpidfile --ignore-ancestors`, `-SIGNAL` anywhere, `--signal SIG` |
| emulated | `pgrep -a/--list-full`, `-l/--list-name`, `-c/--count`, `-d/--delimiter`; `pkill -e/--echo`, `-c/--count` |
| refused | `pkill -v` (signals everything that does *not* match) |
| unavailable on macOS | `-s/--session`, `-O/--older`, `-r/--runstates`, `-w`, `-H`, `-Q`, `--ns`, `--nslist`, `--cgroup`, `--env` — a usage error, not silently ignored |

Two deliberate differences from procps: a process's own ancestors are never
matched (BSD behaviour, which stops `pkill -f foo` from killing the
`bash -c '… foo …'` running it), and a lowercase signal made only of flag
letters stays flags (`-io` is `-i -o`, not SIGIO; `-term`, `-hup` and `-int`
are signals).

## Install

```bash
git clone https://github.com/ai-ecoverse/ai-aligned-pkill
cd ai-aligned-pkill
./install.sh
```

`~/.local/bin` must precede `/usr/bin` on `PATH`; the installer checks and tells
you if it does not. Agents often spawn non-login shells, so on zsh put the
`PATH` export in `~/.zshenv` rather than `~/.zshrc`.

```bash
ai-aligned-pkill doctor
```

## Usage

There is none for the agent. For you:

```
ai-aligned-pkill check <pkill args>  what pkill would signal, and why
ai-aligned-pkill log [N]             the last N decisions (default 20)
ai-aligned-pkill doctor              environment check
```

| environment | |
| --- | --- |
| `AI_ALIGNED_PKILL_MAX=<n>` | blast-radius cap (default 10) |
| `AI_ALIGNED_PKILL_PROTECT=<a:b>` | extra protected path prefixes |
| `AI_ALIGNED_PKILL_HARNESSES="pi claude …"` | argv[0] names that identify an agent harness |
| `AI_ALIGNED_PKILL_DISABLE=true` | pass everything through untouched |
| `AI_ALIGNED_PKILL_DEBUG=true` | trace decisions to stderr |

Agent detection is [am-i-ai](https://github.com/ai-ecoverse/am-i-ai), bundled,
and memoised per session so pgrep polling loops stay fast.

## Limits

This is a guard rail against accidents, not a sandbox.

- **`kill`, `killall` and `ps | grep | xargs kill` are not covered.** The second
  half of the incident command is exactly that, and it is what killed the
  agent's own shell: `grep "[s]erver.mjs"` does not match grep, but it does
  match the `bash -c` whose text contains it. `kill` is a shell builtin and
  cannot be shimmed.
- An agent calling `/usr/bin/pkill` by absolute path bypasses it.
- Orphans are allowed whoever started them; a reparented process carries no
  record of its owner. The cap still applies.
- Harness recognition is by `argv[0]`. A harness not in the list is still
  contained — its children meet the agent's ancestry above the session root or
  hit a terminal or app boundary — but the refusal names it less helpfully.

## Testing

```bash
./test.sh
```

Every process the suite signals is a `sleep` it started, tagged with a marker
unique to the run. Other agents, launchd jobs, login shells and app bundles are
played by `exec -a`, `setpgid` and a symlink under a fake protected prefix.
