# MyMac

A native macOS system monitor and cleaner. Menu bar first, SwiftUI, no third-party
dependencies, no Electron, no web view.

## Install

There is no installer and no release download. You build it:

```bash
git clone https://github.com/<owner>/mymac.git
cd mymac
./Scripts/install.sh          # builds, then puts MyMac.app in /Applications
```

`MYMAC_DEST=~/Applications ./Scripts/install.sh` installs for one user instead.

Nothing was downloaded, so nothing is quarantined and Gatekeeper has nothing to
warn about — an app you compiled yourself is not an app you fetched from the
internet. What the ad-hoc signature does cost is spelled out below: **Open at
Login** refuses, and **Full Disk Access** has to be granted again after every
install, because macOS ties that grant to a code signature and an ad-hoc one
differs from build to build.

To remove it, quit the app and drag `MyMac.app` to the Trash. The only thing it
leaves behind is `~/Library/Preferences/com.mymac.app.plist`.

## Build and run

```bash
./Scripts/build-app.sh release   # produces build/MyMac.app, universal
open build/MyMac.app

swift test                        # 180 tests
```

Requires Xcode 16+ / Swift 6. The command line tools on their own are enough for
`MYMAC_UNIVERSAL=0`, but not for the universal build: two `--arch` flags send
SwiftPM through Xcode's build system, and without Xcode installed it stops at
`xcbuild executable ... does not exist`. Deployment target is macOS 14.

The bundle is a **universal binary** — arm64 and x86_64 — so a copy built on
one kind of Mac runs on the other. Nothing in the source is conditional on the
architecture; the cost is build time, and `MYMAC_UNIVERSAL=0` skips the second
slice while you are iterating.

SwiftPM produces a bare executable, so `Scripts/build-app.sh` assembles the
`.app` bundle around it (`Resources/Info.plist` + ad-hoc signature). There is no
Xcode project to keep in sync. To ship it, replace the ad-hoc signature with a
Developer ID identity — that is also what **Open at Login** needs, since
`SMAppService` refuses a bundle that is not signed with one. With the ad-hoc
signature this build script produces, that toggle will refuse and say so.

Licensed under the MIT licence; see `LICENSE`.

## Layout

```
Sources/MyMacCore/         no AppKit, no SwiftUI — testable on its own
├── Core/System/           MachHost (cached ports), MetricsActor
├── Core/Utilities/        RollingWindow, Format
├── Models/                CPUStats, MemoryStats, DiskStats, …
├── Services/              one collector per subsystem + SystemMonitor
└── Cleaner/               PathSafety, CleanupCatalog, scanners, engine

Sources/MyMacUI/           the app — a library, so it can be tested
├── App/                   MyMacApp, MetricsStore, DockPolicy
└── Features/              Dashboard, MenuBar, Processes, Cleaner, Settings

Sources/MyMac/             main.swift, one line, calls MyMacApp.main()
```

The app is a library and the executable is a single line for one reason: SwiftPM
cannot link a test target against an executable, and leaving the app layer
untested is what let a login-item message that erased itself and a timeout that
could never fire both ship. `Tests/MyMacCoreTests` covers the core,
`Tests/MyMacUITests` covers the models, the sampling lifecycle and the menu bar
drawing.

Two rules keep this honest: the core never imports AppKit or SwiftUI, and the UI
never calls a Mach API. Anything AppKit-only that the core needs is injected —
running application names arrive as a `[pid_t: String]`, and "is this app
installed?" arrives as an `ApplicationInventory`.

## How the metrics are read

Everything comes from a system API. No `top`, `ps`, `vm_stat`, `df`, `iostat` or
`system_profiler` is spawned, at any point, for anything.

| Metric | Source |
| --- | --- |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, `host_processor_info` per core, `getloadavg` |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `sysctl vm.swapusage`, `sysctl kern.memorystatus_vm_pressure_level` |
| Disk capacity | `URLResourceValues` (`volumeAvailableCapacityForImportantUsage`) |
| Disk throughput | `IOBlockStorageDriver` statistics from the IORegistry |
| Battery | `IOPSCopyPowerSourcesInfo` + the `AppleSmartBattery` IORegistry node |
| Network | `sysctl NET_RT_IFLIST2` (64-bit counters), `NWPathMonitor` for the primary interface |
| Processes | `sysctl(KERN_PROC_ALL)` + `proc_pid_rusage` |

Some deliberate choices:

- **Memory used** is app + wired + compressed, the way Activity Monitor computes
  it. File-backed pages the kernel can evict for free are reported separately as
  *cached* and are not counted as used. Memory pressure comes from the kernel's
  own level, not from a ratio invented here.
- **Available disk space** is `volumeAvailableCapacityForImportantUsage`, which
  includes purgeable content — the number that matches what you can actually
  reclaim. Network volumes are skipped; their capacity is not this Mac's.
- **Memory is shown as a composition bar**, not a percentage: what the memory is
  being used *for* is the useful question. A machine holding evictable file cache
  and one that is genuinely out of room look identical as a percentage.
- **Battery status** is derived once, in `BatteryStats.activity`, so the menu
  bar, the dashboard and the detail page cannot disagree. "Time remaining" only
  means something while discharging: on mains power there is nothing to count
  down to, and a Mac held at 80 % by optimised charging is neither charging nor
  draining, so it reads "Not charging" rather than "Calculating…" — a message
  that promised an answer which was never coming. The icon is derived from the
  same state, so the symbol and the words always agree.
- **Battery time remaining** is shown only when macOS reports a settled estimate.
  Battery temperature is not shown at all: the SMC key's unit differs between
  Intel and Apple Silicon and a wrong reading is worse than none.
- **CPU tick counters are 32-bit** and wrap; deltas use `&-` so a wrap does not
  produce a spike.

## Sampling

Sampling is demand-driven and stops entirely when nothing is displaying metrics.

| Scope on screen | Interval |
| --- | --- |
| Menu bar readout | 3 s |
| A window with live charts | 1 s |
| Disk and battery | every 15th sample |
| Processes | 2 s, and only while a process list is visible |
| Filesystem | never, except when you press Scan |

All collectors run on one global actor (`MetricsActor`), off the main thread.
The main actor only receives immutable snapshots.

Measured on an 8-core Apple Silicon Mac (release build):

| | CPU | Memory |
| --- | --- | --- |
| Menu bar readout off (idle) | ~0 % | 15 MB |
| Menu bar readout on | ~0.5–1.5 % | 17 MB |
| Dashboard open, process list live | ~2–10 % | 78 MB |

Per-sample cost, from `swift test --filter SamplingCost`: CPU 0.016 ms, memory
0.003 ms, network 0.6 ms, battery 0.5 ms, processes 1.4 ms (657 processes), disk
6 ms.

Three findings from profiling and driving the running app are worth recording,
because each cost far more than the sampling itself:

1. Reading an observable property inside `App.body` invalidates the **entire**
   scene graph on every change. The menu bar readouts are now stored properties
   assigned only when the rendered string differs, and they are read inside the
   label view rather than in `App.body`. This alone took idle CPU from ~20 % to
   ~3 %.
2. `MenuBarExtra` must be declared before the `Window` scene, otherwise SwiftUI
   opens the window at launch and a "menu bar utility" is silently running a full
   dashboard the user never asked for.
3. Changing the activation policy *while a window is appearing* makes AppKit tear
   that window straight back down a few seconds later. `DockPolicy.promote()`
   therefore runs before `openWindow`, never from the window's own `onAppear`.

## Menu bar behaviour

The status item is **drawn, not composed**. SwiftUI's
`Text("\(Image(systemName:)) 43%")` reports the symbol to accessibility but does
not actually paint it inside a `MenuBarExtra` label — the result was two
percentages with a blank gap where each icon should have been. `MenuBarIcon`
renders the whole readout into one `NSImage` instead: the layout is exact, it is
a single node for AppKit to lay out, and marking it as a template lets macOS tint
it correctly in light mode, dark mode and while highlighted.

With both metrics shown they are **stacked on two lines**, which took the item
from 132 pt wide to **63 pt** — a menu bar is shared real estate, and two
readouts side by side read as two separate items rather than one. Numbers are
right-aligned in a slot sized for "100%", so the item keeps a constant width
without padding the string, which would open a visible gap after each symbol.
Either readout can be switched off in Settings; with both off the item is a
single icon and sampling stops entirely.

Two behaviours are handled explicitly because they are easy to get wrong:

- **The status item's view is not a reliable lifetime.** macOS destroys and
  recreates it when the menu bar auto-hides, when a full-screen app covers it,
  and when the item overflows off a notched display. The sampling scope is
  therefore owned by the app and only released when the user turns the readout
  off — never by the view disappearing. Verified: the readout keeps updating
  while the menu bar is hidden behind a full-screen app.
- **Choosing an action destroys the view that triggered it.** The popover
  dismisses first, and the request is handed to `AppState` and carried out by the
  menu bar label, which outlives the popover. Opening a window from inside a
  view that is being torn down is why the action silently did nothing before.

Popover rows highlight on hover and carry their shortcuts on the right, the way
an AppKit menu does. A single click toggles it whether the app is currently a
menu bar agent or a regular app with the dashboard open.

## Dashboard and CPU layout

Neither page scrolls. A dashboard that scrolls is not a dashboard — you cannot
read the state of the machine at a glance when half of it is below the fold, and
the scroll bar itself is a standing admission that the layout does not fit.

The metric cards have fixed row heights, so they never stretch into empty space.
The vertical slack goes to the process list instead, which shows as many rows as
it has room for — a taller window means more processes, not bigger gaps. The
window's minimum size (880 × 620) is set so both pages always fit.

Per-core load is a row of bars rather than one text row per core: it reads in a
glance, and it stays one line tall whether the machine has 8 cores or 24. On
Apple Silicon the split between busy efficiency cores and idle performance cores
is visible immediately.

A third rendering trap cost a while to find: a paragraph carrying
`.fixedSize(horizontal: false, vertical: true)` inside a card that fills its
row's height leaves SwiftUI with an unresolvable layout, and the symptom is not a
squashed paragraph — the **entire window** stops drawing, sidebar included, while
the accessibility tree still reports every element as present. Text wraps without
the modifier, so no card that fills height uses it.

Two charts needed different treatment for the same reason. A gradient under the
line suits a value that spends most of its time near zero, like network
throughput. Memory sits at 85 %, where the same gradient fills the whole card and
becomes a solid block, so it uses a much fainter wash. Per-process CPU keeps one
decimal below 10 %, because rounding to whole numbers turns the entire column
into zeros.

Reading the Wi-Fi radio is the most expensive part of a network sample: CoreWLAN
took it from 1.1 ms to 4.8 ms and kept a chattering XPC connection to `airportd`
alive, which pushed idle CPU from 0.3 % to 3–6 % and memory from 17 MB to 66 MB.
The radio is now read only while a page that displays it is on screen, and then
at most every few seconds.

A worse bug hid in the per-process CPU figures for a long time. `proc_pid_rusage`
reports `ri_user_time` and `ri_system_time` in **mach absolute time units**,
despite the field names. On Intel a tick happens to be one nanosecond, which
hides the mistake completely; on Apple Silicon a tick is 41.67 ns, so treating
ticks as nanoseconds under-reported every process by **24×**. A thread spinning
flat out read as 2.4 %. It surfaced only when a deliberate busy loop failed to
trip the sustained-CPU detector, and a test now pins the conversion by spinning a
thread and asserting it reads as a large fraction of a core.

Two more costs were found by measuring rather than guessing. Reading the primary
interface's IP addresses needs a `getifaddrs` walk, which took the network sample
from 0.6 ms to 5.2 ms — an order of magnitude more than everything else combined
— so addresses are cached and refreshed only when the interface changes. And the
large-file scan used to crawl every `node_modules` and `.git` in the home folder;
skipping trees that cannot hold a multi-gigabyte single file turned a
multi-minute crawl into seconds.

## What each page shows

Every detail page is built from the same three parts — a hero with the headline
number and its chart, a band of `StatTile` figures, then whatever is specific to
that subsystem. Five pages that share a skeleton read as one product; five
bespoke layouts read as five screens that happen to ship together.

| Page | Beyond the headline number |
| --- | --- |
| CPU | Chip name, performance/efficiency core split, uptime, live process and thread counts (`processor_set_statistics`), load average against core count, per-core bars |
| Memory | Composition bar (app / wired / compressed / cached), swap meter, swap in-out rates, page-in rate, compressor ratio, largest consumers |
| Storage | Purgeable space, read/write throughput **and** IOPS, per-volume list |
| Network | IP address, **router**, **DNS resolvers**, negotiated link rate, MTU, packet rates, errors and drops, peak throughput, totals since boot *and* this session, VPN / metered / low-data flags, per-interface breakdown, and **Wi-Fi radio conditions** |

Throughput counts **physical interfaces only**. A packet crossing a VPN is
counted twice by the kernel — once on the `utun` device and again on the `en`
device carrying it — so adding both reported roughly double the traffic that
actually moved. Tunnels, bridges and Internet Sharing interfaces are left out of
the total and still listed individually, which is where seeing that a VPN is
carrying the traffic is the point.
| Battery | Cycles, capacity vs new, condition, mAh now/design, voltage, live watts, adapter model and rating, Low Power Mode |

The Wi-Fi card reports signal strength, the **noise floor**, and the gap between
them. Signal strength alone is a poor guide — a strong signal in a noisy room is
still a bad link — so the signal-to-noise ratio gets equal billing, alongside the
channel, band and width. The network name is deliberately absent: macOS gates the
SSID behind Location Services, and asking for a location permission to show one
label is not a trade this app makes. Everything else on that card needs no
permission at all.

The **public address** is the one thing on the Network page that cannot be
answered locally: a machine behind NAT has no way to know its public address
without asking something outside. So it is the app's only outbound request. It
runs while the Network page is open, the answer is cached for fifteen minutes,
the endpoint is named in the interface next to the result, and the session is
ephemeral. Addresses — local, router, DNS and public — all carry a copy button,
because an address is a thing people paste somewhere else.

Router and resolvers come from the system configuration store rather than the
routing table or `/etc/resolv.conf` — the latter is a symlink that does not
reflect per-service configuration, and on this machine the real resolvers turned
out to be a local proxy that `resolv.conf` never mentions.

Two figures are worth calling out because almost nothing surfaces them. The
**compressor ratio** says how much RAM the compressor is actually saving. And
**watts at the battery terminals** answers "what is this costing me" — it reads
zero on mains power without charging, which is correct rather than missing.

## Typography

macOS renders `.caption`, `.caption2` and `.footnote` at 10 pt. That is below
what stays legible for dimmed secondary text, so the app defines its own scale in
`Font+`: nothing is smaller than **11 pt**, and every `minimumScaleFactor` floor
is set so a shrinking label cannot fall through it either. Where a label would
still have to truncate — a two-column legend inside a dashboard card — it stacks
onto a second line instead, because "Compress…" is worse than using the space
below.

## Navigation

Dashboard card titles are links. Clicking **Storage** on the dashboard opens the
Storage page — a card that summarises something should take you to the thing it
summarises. The chevron appears on hover, so the affordance is discoverable
without adding permanent clutter. `⌘1`…`⌘9` and `⌘0` jump straight to a section,
the way a browser numbers its tabs.

## The cleaner

The safety model is an allowlist, in `CleanupCatalog`. Every category names one
exact directory; there is no pattern anywhere that could expand to something
unintended. Adding a category means adding a rule in the open, with an
explanation the user reads in the interface.

Beyond the system locations, the catalog covers the caches developer tools keep
**outside** `~/Library/Caches` — anything inside it is already covered by the
Application Caches rule, and a second entry would report the same bytes twice.
A test enforces that: overlapping roots fail the build unless the overlap is
listed as reviewed, with the reason the outer rule provably skips the inner path.

| Rule | Measured here |
| --- | --- |
| npm (`~/.npm/_cacache`) | 2.98 GB |
| pnpm store | 2.48 GB |
| Shared tool cache (`~/.cache` — pip, Puppeteer, …) | 6.99 GB |
| Gradle | 1.41 GB |
| Cargo registry | 815 MB |
| Bun | 165 MB |
| `node_modules` older than 30 days (deep scan) | reported for review |

Two deliberate omissions:

- **Go's module cache** makes its own directories read-only, so a plain delete
  fails part-way and leaves a broken cache behind. `go clean -modcache` is the
  only correct way to clear it, so the app does not offer to.
- **Docker Desktop** keeps everything in one virtual disk image — 26.8 GB on this
  machine. Deleting files inside it would not shrink it, and deleting the image
  would destroy every container, image and volume. So Docker is *advisory*: the
  size is reported, with a pointer to `docker system prune`, and the row cannot
  be selected. `CleanupRule.Kind.advisory` exists precisely so a category can be
  reported without being deletable.

Flow: **scan → review → select → confirm → clean → report**. Nothing is ever
preselected, the full path of every item is on screen, and the confirmation
states the exact count and size.

`PathSafety` gates every deletion. A path must:

1. be absolute, standardized, and free of `..`;
2. be at least three components below the volume root;
3. not be a symbolic link (checked with `lstat`, never followed);
4. resolve its **parent** through `realpath` — resolving the item itself would
   hide a symlinked component, resolving the parent exposes it;
5. not be a protected directory. This set includes every cleanup rule's own root,
   derived from the catalog, so emptying `~/Library/Caches` can only ever remove
   its children and a new rule extends the protection automatically;
6. not live below `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/.ssh`,
   `~/.gnupg`, or `/System`;
7. be strictly inside a root the rule declared.

The engine re-validates every path immediately before touching it, using the
rule's root as the allowlist — never the scan result, which may be minutes old.
Categories whose items sit at a known depth also carry a required path suffix, so
`~/Library/Containers` authorises deleting a container's `Data/Library/Caches`
and not the container.

Two removal modes: caches, logs, crash reports and derived data are **deleted**
(moving them to the Trash would not free the space, which is the entire point);
everything in *Review Before Cleaning* is **moved to the Trash** so it can be put
back.

Scanning is asynchronous, cancellable, streaming, and low priority. Directory
sizes are accumulated one URL at a time and nothing is retained, so a folder with
a million files costs bounded memory. A file disappearing mid-scan is normal and
is ignored, not reported as an error.

Duplicate detection compares content, never names: group by exact size, then by a
hash of the first 64 KB, then by a full streaming SHA-256 in 1 MB chunks. The
oldest copy is treated as the original and is never listed.

## The uninstaller

Removes an application or a globally installed package, and shows exactly what
will go first. **Applications and Others are separate lists**, because they are
different kinds of thing: one is a bundle you drag to the Trash along with its
support files, the other is an entry in a package manager's own registry. The
columns, the footer and the removal mechanism all differ, so a single mixed list
would have to lie about one of them. The manager filter appears only on the
Others tab, where it means something.

The list is **alphabetical by default**, with an optional sort by size. Size
order deliberately waits until every size has been measured: re-sorting as each
measurement lands would move rows out from under the pointer, and every row here
carries a destructive button.

**Listing never runs a subprocess.** Every manager here lays its packages out on
disk in a documented shape, so the app reads that directly: Homebrew's
`Cellar`/`Caskroom`, the `node_modules` of npm/pnpm/Bun, Yarn's global
`package.json`, and Python's `.dist-info` directories. That is faster than
shelling out, cannot break when a tool changes its output format, and works even
when the tool is missing from the app's `PATH`.

Yarn needed the manifest rather than the directory: Yarn v1 hoists every
transitive dependency into one flat `node_modules`, so reading the directory
reported **347** packages instead of the 6 the user actually installed — and
uninstalling one of them would have broken the package that needed it.

**Uninstalling** is the one place an external program runs, because deleting a
package's files by hand leaves its manager's bookkeeping inconsistent. It goes
through `CommandRunner`, which uses `Process` with an argument vector — there is
no shell anywhere, so nothing a package name contains can be read as syntax.
Names are validated against a conservative character set anyway, a leading `-` is
refused so a name can never be mistaken for a flag, and the exact command is
shown in the confirmation sheet before it runs.

Applications are pure AppKit: the bundle and its selected support files go to the
**Trash**, never straight out. Leftovers are found by bundle identifier across
the twelve places macOS keeps per-app state, plus Group Containers, whose names
carry a team identifier in front of the bundle identifier. Two further folders —
`Application Support/<name>` and `Logs/<name>` — are matched on the app's
display name, because that is the established convention in those two and
nowhere else; the confirmation sheet says the list is keyed on the identifier
rather than claiming to be exhaustive. Those folders are the only roots
`PathSafety` will accept at removal time. Two honest limits are stated
in the interface rather than papered over:

- An app that is **running** is flagged, because its state gets written back out
  after removal.
- A vendor folder shared by several apps — `~/Library/Application Support/Google`
  — is **not** attributed to any one of them. Matching on a bundle identifier is
  a fact; matching on a vendor name is a guess.

Apple's own applications are excluded outright.

## Watching for processes behaving badly

The process list flags anything sustaining unusual resource use and offers to
quit it. Two signals, both measured rather than guessed:

- **Sustained CPU** — every sample in a rolling window must exceed most of a
  core. An average would not do: one long spike inside an otherwise quiet window
  is not a stuck process, and flagging every burst would teach the user to ignore
  the feature entirely.
- **Growing memory** — a footprint that grew by a gigabyte across the window and
  now stands above three. Below that floor, growth is not worth mentioning
  however fast it is.

Quitting is a two-step the user drives. A GUI app is asked through
`NSRunningApplication.terminate()` so it can save open documents; anything else
gets `SIGTERM`. Only if the process is still there three seconds later is Force
Quit offered, and that is a separate button, never automatic. PID 1 and the app's
own process are refused outright.

**What this cannot do is detect a beachballed app**, and it does not claim to.
macOS exposes no public way to ask: `kinfo_proc.p_stat` reports every one of the
573 processes on this machine as "running", a hung app is indistinguishable from
an idle one by CPU time, and the call Activity Monitor uses is private. Guessing
would produce exactly the kind of false alarm this app exists not to show.

## Storage breakdown

The Storage page can work out where the space went, but only when asked — the
button is there precisely because the analysis walks the whole disk and takes
around two minutes on a full machine. It never starts because a tab was opened.

Each row that corresponds to a real folder is clickable and opens it in Finder:
"41 GB in Projects" invites an obvious next question, and the answer should not
be a path you have to retype. The remainder row has no folder, so it is not
clickable.

Every folder it measures is disjoint from the others, so the numbers add up and
nothing is counted twice: each top-level entry of the home folder, `/Applications`,
and `~/Library` expanded one level so its biggest rooms are named rather than
lumped together. Whatever is left over — the system itself, other users, anything
outside the home folder — is reported honestly as one remainder rather than
quietly dropped. Four folders are measured concurrently, which is enough to keep
an SSD busy without thrashing the walk, and the whole thing is cancellable.

## Settings and permissions

Settings is a **page in the main window**, not a second window. A separate
settings window would have shown a subset of what the main window already shows,
in a different visual language, with its own copy of anything that overlapped.
`⌘,` still works — it navigates to the page, as does the menu bar item.

The page is three tabs — General, Menu Bar, Permissions — because each group then
fits without scrolling, and a settings pane that scrolls hides half of itself.
The Menu Bar tab previews the status item using the same drawing code the menu
bar uses, so the preview cannot drift from the real thing.

**Permissions live inside Settings**, so the whole list can be seen and decided on
in one place rather than meeting a system prompt part-way through a task. Nothing
is requested at launch, and nothing is requested on its own — every prompt there
is raised by a button the user pressed.

Both permissions are optional:

| | Unlocks | Without it |
| --- | --- | --- |
| Full Disk Access | Caches belonging to Safari and Mail; local iPhone/iPad backups | Everything else. Most sandboxed app caches are readable already — 36 of 38 on the machine this was built on — and the protected few are shown as skipped rather than reported as empty |
| Location | The name of the joined Wi-Fi network | Signal strength, noise, channel and link rate are all still shown; macOS gates only the name |

macOS offers no API to query Full Disk Access, so it is **probed**: the TCC
database is readable only by an application that has been granted it, so the app
reads one byte and keeps nothing. Full Disk Access cannot be requested
programmatically at all, so that row opens the right Privacy pane instead of
pretending it can.

The page also lists what the app **never** asks for — Accessibility, Screen
Recording, Camera and Microphone, Contacts, Photos, an administrator helper. The
absence of a prompt is easy to miss, and the list of what an app does *not* use
says more than the list of what it does.

There is no privileged helper and no `sudo`. Nothing in this app runs as root,
which is also why some things are out of scope (below).

Note for anyone building this: TCC grants are tied to a code signature, and the
build script signs ad-hoc. Granting Full Disk Access to a locally built copy
works, but the grant will not survive a rebuild — sign with a Developer ID
identity for that.

## Known limitations

- **Processes owned by other users report no CPU or memory.** `proc_pid_rusage`
  refuses them without elevated privileges. Those rows are listed with `—` and
  sorted last rather than dropped or filled with zeros. Roughly 430 of 657
  processes are readable on a typical machine.
- **System-level cleanup (`/private/var/log`, system caches) is not implemented.**
  It requires a privileged helper, and one is not worth adding for the small
  amount of space involved.
- **Simulator devices are not offered for deletion.** Removing them from disk
  desynchronises CoreSimulator's database; that needs `simctl`, which means
  shelling out.
- **CPU usage per process is a fraction of one core**, so a busy multithreaded
  process can exceed 100 %, matching Activity Monitor.
- **Two network totals are shown**: *since boot*, taken from the interface's own
  cumulative counters, and *this session*, counted from the moment monitoring
  started. Neither is a substitute for the other, so both are on screen.
- **The Location permission currently unlocks nothing.** The Wi-Fi network name
  is read and then discarded: no view displays it, so granting Location changes
  nothing on screen while the Wi-Fi card still says the app does not ask for it.
  Two sections of this file disagree about whether the name should be shown at
  all. That is an open decision, not an oversight to work around — either the
  name gets displayed or the permission comes out entirely.
- **Open at Login needs a real signature.** With the ad-hoc signature from the
  build script, `SMAppService` will refuse and the toggle reports why.
