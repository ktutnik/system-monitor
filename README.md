# System Monitor

A menu-bar system monitor with two underline tabs: **Net** (what is talking to the network,
and where it went) and **Battery** (hour-by-hour charge history).

    ./install.sh             build, install to ~/Applications, start it
    ./install.sh --login     the same, and start it at every login
    ./uninstall.sh           remove the app and the login item, keep the history
    ./uninstall.sh --purge   remove the history too

`./build.sh [path]` builds the bundle on its own if that is all you want.
Quit the app from the gear menu at the bottom right of the dropdown.

## Status

Both tabs work. The app installs as `SysMonitor.app` under
`local.ktutnik.sysmonitor`.

**It samples nothing.** Both panes read the store written by the `vitals` daemon
([vitals](https://github.com/ktutnik/vitals)), which records continuously whether or not this panel is
ever opened. This app is a reader and a renderer; when the dropdown is shut it
owns a menu-bar item and does nothing else.

**Net tab** — a folder tree, **App › Went To, Chart, Down, Up**. Each app is a
folder carrying its own totals with its destinations nested under it. Apps are
alphabetical so a given one sits in the same place every time; destinations
inside a folder are busiest-first. Because the order no longer ranks anything,
the CHART column is the only thing that says who is loudest — every bar, parent
and child, is measured against the busiest *app*, so a child bar reads as a
slice of its parent and any two rows on screen compare directly. Folders start
shut. Rows are app/destination pairs, so traffic with no peer is a row of its
own ("No destination") rather than a gap, and the table sums to the header.

**Both tabs are daily reports, navigated identically.** Back and forward a day
at a time, a calendar, a "Today" link that appears only when it would do
something, and the live readout on the right — the charge on one tab, the
current throughput on the other. Both charts pin their axis to the whole day,
midnight to midnight, at the same 15-minute resolution and the same geometry,
so a traffic spike lines up by eye against the charge curve underneath it.
Today's chart shades the part of the day that has not happened yet; without it
an empty afternoon and an afternoon still to come draw the same.

This replaced a rolling **15m / 1h / 6h / Today** picker. The windows answered
"what is it doing right now"; a day answers "what did it do", which is what the
store can now actually support — the daemon records continuously, so all 14 days
it keeps read as well as the current one. The cost, stated plainly: there is no
longer a way to narrow to the last fifteen minutes. Today's view is live, so
"now" is still there at the right-hand end of the chart, just not isolated.

Paging back to a past day also stops the app asking the daemon for its 2-second
rate — that claim is renewed only while today is on screen. Reading Tuesday
cannot be made more accurate by sampling faster now, and the watched rate costs
the daemon roughly six times the rows.

**A dimmed name with `exited` after it** means no process behind those rows is
still running. It is a live fact, recomputed with the table rather than read
out of the store — the store only knows that bytes moved. It is about the
processes that moved them, so an app that has since been started again still
reads as exited, which the tooltip says. On a past day the useful half is the
opposite one: a row that is NOT dimmed has been running since that day.

**The badge in front of each app is who signed it** — Apple, the App Store, a
Developer ID, ad-hoc, or nothing at all. Read it as identity, never as a
verdict: it says who signed the binary and that the binary is unmodified, and
notarised malware exists. What it is good for is the odd one out — something
claiming to be a well-known app with no signature behind it.

It is read two ways, cheap first. A **running** process answers in 1.15ms,
because the kernel already validated it. Anything that has since exited is
checked from the executable path the daemon wrote to `netpath/<date>.tsv`, which
costs 42ms because the binary has to be re-hashed — so paths are only tried for
apps no live process could answer for, always off the main thread, and the
answer is remembered. That second route is what finally labels the short-lived
command-line tools (`ssh`, `gh`, `whois`, `uv`) that are almost never alive when
the panel is open; on this machine it took a day's table from 26 of 44 apps
labelled to 30, and from a **permanent** gap to one that closes as the daemon
records more. Verdicts are still also remembered by name, which is the only
thing that can label a day recorded before the side table existed.

A dotted outline means *not checked*, which is deliberately not the same glyph
as anything that was. It still happens: a pid with no recorded path — a day
older than the side table, or a process that exited before the daemon could read
its path — stays honestly unknown. The path is matched by **time**, not by pid
alone: pids are recycled, so an entry recorded after the row was written is
never used. Naming the wrong binary would be worse than naming none.

**Battery tab** — the daemon's battery stream, with each hour row now carrying a
second line: the three processes that did the most CPU work in that hour. It sits
**under** "what was in front" rather than replacing it, because the two answer
different questions — what I was doing, and what was working hard — and they
disagree more often than not. See below for why it is labelled CPU and nothing else.

**The week-gap is gone.** The trade described below — history only when you open
the panel, gaps longer than a week unrecoverable — no longer applies, because
the daemon records regardless. The text is kept because it still explains why
this app is shaped the way it is.

**A missing daemon is visible.** If `vitals` is not recording, the pane says so
in words and the totals show `—`. An empty table and a dead producer must never
render the same way; that is the one failure this design can cause silently.

**Idle silence holds, measured.** With the dropdown closed the process CPU time
does not advance at all over a minute (0.01s over two, against 0.0 Energy Impact).
Open, a refresh of the default fifteen-minute view costs 0.03ms rather than 19.81ms,
because the Net pane follows each day file by byte offset instead of re-parsing it;
`NetReader` holds that state and is discarded on close like everything else. Nothing in `Sources/` registers a timer,
a run-loop source or a notification observer outside code that runs between
dropdown open and close.

### What is not done, or not proven

- **The install migration has never run against a real old install**, and can no
  longer be tested here: the app has already created its directory, and the
  migration deliberately refuses to touch an existing one, so it will always
  skip from now on.
- **The static menu-bar icon has never been deliberately reviewed in situ.**
  `screencapture` cannot be used from a terminal without Screen Recording
  permission, and the app's own `--render` draws the dropdown, not the menu bar.
- **18 rows in the daemon's first day of net data are torn** — written before
  `O_APPEND` landed there. This app skips malformed rows; they age out with the
  daemon's 14-day retention.
- **The app is one release behind its own history.** The legacy battery store at
  `~/Library/Application Support/SysMonitor/` is still written as a fallback and
  still read when no daemon store exists. Nothing prunes it.

The daemon's own docs and contract live in [vitals](https://github.com/ktutnik/vitals).

## Design rules

**Nothing runs while the dropdown is closed.** No timers, no reading, no event
observers — the app owns a menu-bar item and does nothing else until it is opened.
This is the central constraint, not an optimisation, and it survived the move to
the daemon: recording is now someone else's job, but rendering is still only
done while someone is looking.

**Every dismissal route must stop the work.** The panel closes itself on an
outside click or Esc through its own event monitors, without going through the
status item, so `DropdownPanel.onClose` is the single place anything can hang
off. This is not a detail — when the net reader missed it, it re-parsed its
whole window every 2s behind a panel nobody could see, and the only symptom was
a number in Activity Monitor.

**The menu-bar icon is static.** One template image, set once at launch. macOS
already shows a battery percentage; a second one of ours would need a refresh
timer, and the rule above forbids it.

**The app must be honest about its own cost.** An app that reports battery drain
has no business causing it. With the dropdown closed, its CPU time must not advance
at all: note `ps -o time=`, wait ten minutes without opening it, read it again, and
the two numbers should be identical.

## What the Battery tab is, and its one trade-off

The system only remembers about a week of past charge, so the app keeps a store of
its own at `~/Library/Application Support/<name>/YYYY-MM-DD.tsv`, backfilled from
`powerd`'s own log — `log show --predicate ... --start`, which is asked only for the
stretch the store does not already cover.

**The backfill is gap-driven, not open-driven.** A persisted coverage mark says how
far history is known to be complete; an open whose mark is fresher than fifteen
minutes returns on that comparison and spawns nothing. This replaced `pmset -g log`,
which takes no arguments and so cost 13.8MB and ~3s of CPU on every single open to
recover, typically, nothing. Note the mark tracks COVERAGE, not the newest sample:
a query that finds nothing still advances it, or a machine parked on AC at 100% —
where `powerd` emits no events at all — would re-query a widening window forever.

Because nothing runs while closed, **history is only recorded when you open it**.
Open it at least weekly and the record stays complete, since the backfill reaches
back that far. Go longer than a week without opening it and that gap is gone
permanently — the system's log cannot give it back once it has rotated out, and
nothing else on the machine recorded it. This was a deliberate trade in favour of the idle-silence rule above.
Do not add a background timer back to "fix" it.

Charge at each hour boundary is **interpolated** between surrounding samples. The
log writes only on power events, so whole hours carry no sample; bucketing by
"samples seen this hour" would report those as 0% and dump their drain on a
neighbour hour. An hour with no sample of its own is dimmed — which matters more
now than it used to, because far more hours are interpolated.

Maximum Capacity and cycle count come from `system_profiler SPPowerDataType -json`
(~0.15s), not from an ioreg ratio: neither 7302/8694 nor 7546/8694 reproduces the
83% macOS reports, because macOS smooths it. Using its own figure is the only way
the header matches what System Settings shows the user.

## What the Net tab is

A folder tree — App › Went To, Chart, Down, Up — read from the `vitals` store.
Everything that produces that data lives in the daemon now; what follows is what
a reader of this app needs to know about the data it is drawing.

**Nothing here samples the network.** The framework binding, the name resolution
and the whois/Cymru subprocesses all moved to `vitals`. Two consequences: the
pane is populated the instant it opens rather than climbing from zero over four
seconds, and the app no longer appears in its own table — the resolver's lookups
are attributed to the daemon that makes them.

**Destinations are names, never addresses.** The store records an address and
resolves it separately, so this app joins the two by longest-prefix match at
draw time — a row therefore inherits every later improvement to its netblock's
name, retroactively and for free. When a prefix is not yet known the row says
"Resolving…", never an address.

**Two joins happen at draw time, and neither is stored in the row.** The
destination name comes from `names.tsv` by longest-prefix match; the executable
path behind the signing badge comes from `netpath/<date>.tsv` by pid and time.
Both exist so the net row itself stays small — it is the biggest file in the
store and would otherwise repeat the same handful of values tens of times a
second — and both mean a row can improve after it was written.

**Two limits stated in the UI rather than hidden.** Chrome uses DNS-over-HTTPS,
so the tab can name the host connected to but never the page read; and a shared
CDN address fronts many different sites.

**Why the daemon exists at all** is in the [vitals README](https://github.com/ktutnik/vitals#readme) — chiefly
that `nettop` burns ~140% of a core continuously, which is disqualifying for
anything that runs beside a battery monitor.

## Implementation notes

The dropdown is a plain borderless NSPanel, not an NSPopover. On macOS 26 a popover
draws a ~13pt glass border over its own content view, so the content loses an edge
on all four sides and the inset is not readable from any API.

Offscreen rendering has to pin the appearance on both the window and the hosting
view, or labels come out in the wrong colour with nothing to resolve against.

The login item is a LaunchAgent with `KeepAlive` false, so quitting the app
deliberately keeps it quit until the next login instead of having launchd restart
it a second later.

`--purge` is opt-in because the store is the only copy of anything older than about
a week — the system's own log cannot give it back once it has rotated out.

All three scripts honour `APP_DIR`, `AGENT_DIR` and `DATA_DIR` if you want to test
them somewhere harmless.

## The "what was in front" column is not a measurement

macOS keeps no historical per-process power data — nothing on the machine can say
what drew watts at 11am. That column is foreground-app time from the daemon's
`activity/<date>.tsv`, the closest available proxy. It is blank when that stream
is absent, and it should never be read as measured power.

## The "top CPU" line under it is a measurement — of CPU, and of nothing else

The second line of each hour row is real: `cpu/<date>.tsv` from the daemon,
summed per process over the hour. Three things about it are load-bearing.

**It is CPU work. It is not energy, power, watts or battery use, and no label in
this app may say otherwise.** The temptation is specific and was nearly taken:
`proc_pid_rusage` returns a field called `ri_billed_energy` that sounds exactly
like attributed energy. It reads zero for the browser burning a core, zero for
86% of running processes, and sums to a thousandth of what the laptop actually
draws. The daemon deliberately records cycles instead and named the stream `cpu`
for that reason — see the vitals [CONTRACT.md](https://github.com/ktutnik/vitals/blob/main/docs/CONTRACT.md) §5. Heading this
column "energy" would undo that work at the last step, which is why it is said
here rather than left to be inferred.

**Ranked on cycles, shown as time.** The cores are not interchangeable — measured
on this machine the same day, 3.2GHz on a performance core against 1.0–1.6GHz on
the efficiency ones — so two processes with equal CPU milliseconds can differ
threefold in work done, and wall time cannot see it. The cut is taken on cycles;
the figure printed beside each name is CPU time, because that is the number every
other tool shows. The tooltip carries both, plus the average clock the work ran
at, which is `cycles / cpu_ms` and is how you tell afterwards which kind of core
it landed on.

**"Not recorded" and "nothing busy" are different sentences, deliberately.** The
daemon only writes a process above ~50M cycles a minute, so a quiet hour
genuinely produces no rows and *nothing busy* is a fact. An hour outside the
stream's coverage also produces no rows, and there the only honest statement is
that nobody was looking. Three states, three renderings:

| Hour | Reads |
|---|---|
| Work recorded | `Google Chrome 22s · claude 6s · Zed Preview 4s` |
| Recorded, nothing crossed the floor (or asleep) | `nothing busy` |
| Outside the stream's coverage | `⃝ CPU not recorded` |

An hour only earns *nothing busy* if it was covered end to end; a part-covered
hour with no rows — the hour recording started in, the hour a daemon died in —
says *not recorded*. On today, coverage runs to **now** while the daemon is live,
so a genuinely idle afternoon reads as idle rather than as unknown.

This is the common case, not an edge one. The stream is 14 days old at most and
battery history is kept forever, so most days in the calendar have a charge curve
and no CPU at all. Such a day drops the second line from every row and says it
**once**, in the column header: `TOP CPU · NOT RECORDED THIS DAY`. Twenty-four
rows repeating it would bury the column that works, and the empty second line
would be exactly the silent failure the design rules forbid.

**What it cannot see.** `proc_pid_rusage` answers only for processes this user may
introspect — 232 of 691 refused when the daemon measured it, and they are the
root-owned ones. A system daemon burning a core does not appear here. The line
answers "which of my programs was busy", never "what was this machine doing".

## Render mode (for checking layout without launching)

    <binary> --render out.png [YYYY-MM-DD] [dark] [cal] [net|battery]
    <binary> --render-icon out.png

Draws the real view offscreen and exits, so layout can be checked without a
screen-recording permission. The trailing words are order-free flags; `battery` is
the default, and the tab it forces is written to the argument domain so rendering
the Net tab does not change which tab the real app opens on next time.

Render mode never starts the sampler, so `--render net` always draws the empty
pane. Set `NETMOCK=live`, `NETMOCK=pending` or `NETMOCK=empty` to draw the
built-in reference capture instead and see a populated Net tab.
