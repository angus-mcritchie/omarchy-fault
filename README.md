# Fault

Your machine tells you when a service dies. Fault is the part that listens.

Failed and restarting systemd units in the Omarchy bar, across **both** the system
manager and the user manager. It draws nothing while everything is healthy.

## Why the user manager matters

Most tools that watch systemd check the system manager and stop there. Your timers,
your agents, your sync daemons and anything you wrote yourself run under the *user*
manager, and it keeps its own state:

```
$ systemctl is-system-running
running
$ systemctl --user is-system-running
degraded          # a unit failed here hours ago and nothing said so
```

Fault watches both, and every unit it shows is tagged with the manager it belongs to.
Unit names are only unique within a manager, so every read and every action is routed
by that tag.

## Silent when green

There is no icon in the bar while both managers are healthy. No tick, no counter
reading zero. The icon appearing *is* the alert.

An empty query result is not the same as health, so Fault separates the two. A manager
that cannot be read gets its own dim "unknown" state rather than being counted as fine:
a health widget that goes green when it fails to read is the exact failure it exists to
prevent.

Because a healthy machine draws nothing, the panel can always be summoned by hand:

```bash
omarchy-shell angus.fault summon     # opens the panel even with no icon showing
omarchy-shell angus.fault status     # one line, for scripts
omarchy-shell angus.fault refresh
```

## What it shows

**Failed units** — name, manager, description, how long ago, what systemd reported, and
the tail of that unit's journal.

**Restarting units** — a unit flapping under `Restart=always` never enters the failed
set until its start limit is exhausted, so `systemctl --failed` cannot see it. Fault
queries `--state=failed,auto-restart` and gives restarting units their own card with the
restart count and the time since the last exit.

**What systemd reported, and nothing more.** Fault does not claim a root cause. It shows
the numeric status with the symbolic name and class where `systemd-analyze exit-status`
supplies one, and the bare number where it does not. `ExecMainCode` is read first,
because `ExecMainStatus` holds a *signal* number when a process was killed rather than
exited, and the low signal numbers collide with named exit statuses. Reading one as the
other would report a core dump as "NOTCONFIGURED". Where a number has a conventional
meaning but no systemd meaning, it is labelled as a convention, because any process may
exit 127 deliberately.

## Read-only, on purpose

Fault observes and explains. It does not restart or reset units.

`systemctl reset-failed` clears a unit's failed state without starting or repairing it.
The unit leaves the failed set while staying inactive and dead, so a self-hiding widget
that offered that button would clear its own icon and report green over a service that
will never run again. Restart and reset belong here eventually, with proper polkit
handling and a re-read of `ActiveState` afterwards. They are not worth shipping as a lie
in the meantime.

**Copy diagnostics** shows you the payload before it copies anything, and says plainly
that service logs routinely carry tokens, URLs, customer identifiers and request data.
It is deliberately not pre-formatted as a ready-to-paste issue.

## Install

```bash
omarchy plugin add https://github.com/angus-mcritchie/omarchy-fault.git --enable
```

## Settings

| Key | Default | Notes |
| --- | --- | --- |
| `intervalSec` | 10 | Two short `systemctl` calls per manager per tick. A unit that flaps and recovers entirely between two ticks is missed. |
| `journalLines` | 20 | Read only while the panel is open. |
| `watchSystem` | true | |
| `watchUser` | true | |

## Requirements

systemd, and `wl-copy` for the clipboard. Reading the *system* journal needs membership
of `wheel` or `systemd-journal`; without it Fault says so on the card rather than
rendering an empty log and looking broken.

## Licence

MIT.
