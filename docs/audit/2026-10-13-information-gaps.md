# What MyMac could show that it does not yet

Date: 2026-10-13. Scope: information the app could surface to be more useful and
credible, checked against the code and against comparable tools (iStat Menus,
Stats by exelban, Activity Monitor, btop, TG Pro, DaisyDisk, CleanMyMac,
AppCleaner). No code was changed.

## Constraints that filter every idea

These come from `CLAUDE.md` and decide what is realistic:

- No subprocess for metrics (no `top`, `ps`, `powermetrics`, `nettop`, `system_profiler`).
- Nothing runs as root; no privileged helper.
- No third-party dependencies; system frameworks only.
- Nothing is requested at launch; every prompt follows a button.

Anything below that needs root or a subprocess is listed under "Ruled out".

## What the app has today

CPU (user/system/idle, per core, load average, tasks, threads, P/E split),
memory (composition, pressure, swap, paging, compression ratio), storage
(volumes, purgeable, throughput, session I/O, breakdown scan), network
(throughput, addresses, router, DNS, Wi-Fi RSSI/noise/channel/rate, VPN, MTU,
errors, public IP), battery (charge, cycles, health, condition, voltage, power,
adapter), processes (CPU, memory, responding), cleaner, uninstaller.

Checked by grep: nothing in `Sources` touches thermal state, GPU, SMC, HID
sensors, notifications, Bluetooth, per-process disk or energy, or export.
`history` exists only as in-memory sparklines.

## Gaps, ranked by value over cost

### Tier 1 — expected of a monitor, feasible inside the constraints

| # | Addition | Source (no subprocess, no root) | Notes |
|---|---|---|---|
| 1 | **Thermal state** (Nominal / Fair / Serious / Critical) | `ProcessInfo.thermalState` + `thermalStateDidChangeNotification` | One line of API. Explains "why is my Mac slow" better than any percentage. Show in CPU page, dashboard badge and menu bar tint. |
| 2 | **GPU utilisation** (and VRAM/memory on Apple Silicon) | IORegistry `IOAccelerator` → `PerformanceStatistics` (`Device Utilization %`, `Renderer`, `Tiler`) | Readable unprivileged. Same IORegistry pattern the disk and battery collectors already use. Largest visible hole against iStat/Stats. |
| 3 | **Per-process disk I/O and energy** | `proc_pid_rusage` already called: `ri_diskio_bytesread/written`, `ri_billed_energy`, `ri_pageins`, `ri_wired_size` | Zero new syscalls. Adds "Disk" and "Energy impact" columns to the process table, and answers "what is hammering my SSD / draining my battery". Remember the mach-time trap for any time field. |
| 4 | **Process detail**: path, bundle id, parent, user, start time, thread count, open file count | `proc_pidpath`, `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pidinfo(PROC_PIDLISTFDS)` | Turns a name into something actionable (is `helper` Chrome or malware?). |
| 5 | **Alerts** (high CPU for N minutes, memory pressure red, disk < X GB, battery health < 80 %, thermal serious) | `UserNotifications`, requested only when the user enables an alert | Strongest "professional" signal: a monitor that tells you instead of waiting to be looked at. Needs a settings card with thresholds. |
| 6 | **Longer history with persistence** (1 h / 24 h / 7 d charts) | Downsampled ring buffers, written to Application Support | Sparklines today forget everything on quit. Needed for "what happened last night". Keep sampling invariants: write from `MetricsActor`, UI gets snapshots. |
| 7 | **Machine identity card** | `hw.model`, `hw.memsize`, `kern.osversion`, `kern.osproductversion`, IORegistry `IOPlatformExpertDevice` (model, serial) | Chip, model identifier, macOS build, RAM, serial, uptime, boot volume, last boot. Today only chip, cores and uptime show. Put in an "About this Mac" card on the dashboard. |

### Tier 2 — valuable, more work or a trade-off

| # | Addition | Source | Notes |
|---|---|---|---|
| 8 | **Temperatures and fan speed** | CPU/GPU/SSD: `AppleSMC` user client (Intel, and many keys on Apple Silicon) or private `IOHIDEventSystemClient` sensors (Apple Silicon) | Readable without root, which is how Stats does it, but keys differ per chip generation. README already refuses a battery temperature because a wrong unit is worse than none; apply the same bar — ship per-chip tables with a test, show "—" when unknown. |
| 9 | **Battery extras**: temperature, charge history, "last full charge", estimated runtime at current draw, adapter wattage vs draw | `AppleSmartBattery` keys (`Temperature`, `AdapterDetails`), own history store | Needs the history store from #6. |
| 10 | **Sleep/wake and power assertions**: what is keeping the Mac awake | `IOPMCopyAssertionsByProcess` | Directly useful, and this author already ships Caffeinate — a natural cross-reference. |
| 11 | ~~Wi-Fi network name~~ **Decided: do not show it.** | — | The name is one click away in the system menu. Consequence: remove the Location permission row and the "name needs Location" note, so the permissions page lists only Full Disk Access. This also closes the open decision in README *Known limitations*. |
| 12 | **Network history**: daily/monthly totals, per-interface | Own persisted counters from `NET_RT_IFLIST2` deltas | Per-app network usage is not possible without `nettop`/NetworkStatistics (private); do not promise it. |
| 13 | **Export / share a snapshot** (JSON or Markdown "system report") | Existing stats structs are already `Sendable` value types | One button; useful for bug reports and support. Cheap once #7 exists. |
| 14 | **Disk health**: SMART status, wear, power-on hours, bytes written | IOKit `IONVMeSMARTInterface` / `NVMe SMART` user client | Works for internal NVMe without root on most Macs; verify on a real machine before shipping. |
| 15 | **Security posture**: SIP, FileVault, firewall, Gatekeeper, XProtect version | `csrutil` equivalents via `csr_get_active_config`; FileVault via `IOKit`/`DiskArbitration`; firewall via `defaults`-like preference read | Avoid spawning `fdesetup`/`csrutil`; use the C APIs. Nice for a "health" summary. |

### Tier 3 — cleaner and uninstaller polish

- **Cleaner**: show *last-modified age* and *confidence* per item; add Homebrew
  cache, `~/Library/Developer/Xcode/iOS DeviceSupport` per-version sizes, Mail
  attachments, old iOS updates, language `.lproj` files (off by default),
  `~/Library/Caches/pip`, Gradle/Maven/CocoaPods/Cargo caches — all by exact
  path, per the allowlist invariant. Add a **history of what was cleaned** (date,
  bytes, categories) and a running total ("freed 14.2 GB so far"). Undo is not
  possible for permanent deletes; say so, and prefer Trash where the catalog
  allows it.
- **Uninstaller**: show app version, last-opened date (`kMDItemLastUsedDate`),
  and install source (App Store / Homebrew / downloaded) so "unused for a year"
  can be sorted; show total leftover size before deleting; surface login items
  and launch agents owned by the app (read plists, do not shell out).
- **Storage breakdown**: add a treemap/sunburst drill-down (DaisyDisk-style) on
  top of the existing analyzer, and a "what changed since last scan" delta once
  scans are persisted.

### Ruled out by the constraints

- **Per-app network bandwidth**: needs `nettop` or the private NetworkStatistics
  framework.
- **CPU/GPU frequency, package power watts, ANE utilisation**: `powermetrics`,
  root only. IOReport can read them unprivileged but is a private, undocumented
  API; treat as a research spike, not a feature.
- **System-level cleanup** (`/private/var/log`, system caches): needs a helper.
- **Process CPU/memory for other users' processes**: `proc_pid_rusage` refuses.

## Apple Silicon and Intel

Every item must work on both, or degrade to "—" on the one where it cannot.
Nothing may be gated by `#if arch(...)`; detect at runtime and test with
injected fixtures so the suite does not depend on the host.

| # | Apple Silicon | Intel | Plan |
|---|---|---|---|
| 1 thermal state | yes | yes | Identical API. |
| 2 GPU | `AGXAccelerator`, `Device Utilization %` | `IntelAccelerator` and discrete AMD, key names differ (`GPU Activity(%)` on some) | Walk every `IOAccelerator` child, try known keys in order, show each GPU found. Unknown key means "—". |
| 3 per-process I/O | `ri_diskio_*` yes | yes | Same. `ri_billed_energy` may read zero on Intel — verify; hide the Energy column when every row is zero. |
| 4 process detail | yes | yes | Same. |
| 5 alerts, 6 history, 13 export | yes | yes | Pure app logic. |
| 7 identity card | `hw.model` is e.g. `Mac14,5`; chip from `machdep.cpu.brand_string` | `MacBookPro16,1`; Intel brand string | Same sysctls. P/E split already degrades correctly. |
| 8 temperatures, fans | HID sensors; fanless Airs have no fan | SMC keys (`TC0P`…) | Two readers behind one protocol, picked at runtime. Hide the fan row when `FNum` is 0. Ship only with a per-chip table and tests. |
| 9 battery extras | laptops only | laptops only | Reuse the existing "No Battery" path. |
| 10 power assertions | yes | yes | Same. |
| 14 SSD SMART | internal NVMe often not exposed | T2 and older SATA/NVMe differ | Spike on one machine of each kind first; drop if it cannot be done honestly. |
| 15 security posture | yes | yes | Same C APIs. |

## UI/UX rules for the new information

The app already has a consistent shape: dashboard cards, one detail page per
subsystem, a menu bar popover. New data goes into that shape, not beside it.

1. **No new top-level sections.** GPU and thermal live inside the CPU page and
   the dashboard CPU card; process I/O and energy are columns in the existing
   process table; identity is one card. The sidebar stays at ten rows.
2. **Progressive disclosure.** Dashboard shows one number or badge per
   subsystem; the detail page shows tiles; per-core, per-process and raw
   counters stay one level deeper. A tile that is "—" on this Mac is removed,
   not shown empty.
3. **Show state, not only numbers.** Thermal, memory pressure and battery
   condition use one shared four-level vocabulary and tint (normal / fair /
   serious / critical) so the same colour always means the same thing.
4. **Explain once, briefly.** One caption line per card where a figure is
   easy to misread (as the memory and battery pages already do), no paragraphs.
5. **Settings stay small.** Alerts get one card with a master switch and a few
   presets; thresholds are an "Advanced" disclosure, off by default. Nothing
   asks for permission until its switch is turned on.
6. **Charts are time-ranged, not decorated.** One shared range control
   (1 h / 24 h / 7 d) for every history chart; no per-chart variants.
7. **Menu bar stays minimal.** New data is opt-in there; the default readout
   does not grow.
8. **Accessibility and tests.** Every new element gets an accessibility label;
   do not add UI tests that press permission buttons, and keep sampling frozen
   under `-MyMacUITesting YES`.

## Suggested order

1. #1 thermal state, #3 per-process disk/energy, #7 identity card: each is a
   few dozen lines on data already in hand, and visibly closes the gap.
2. #2 GPU: the largest missing headline metric.
3. #5 alerts + #6 persisted history: together they change the app from a
   dashboard into a monitor. Design the history store first; #9, #12 and the
   cleaner totals all reuse it.
4. #8 temperatures/fans, only with per-chip tables and tests.
5. #13 export, then Tier 3 polish.

## Open questions

- Is the target audience developers (Xcode/Docker/node caches matter) or general
  users (security posture, disk health matter more)?
- Does persisted history belong in `MyMacCore` behind a protocol, with the UI
  never touching the files? Probably yes, to keep the layering invariant.
- #8 and #14 should be verified on real hardware of both architectures before
  committing to a design; I have not run either.

## Evidence and limits

Competitor feature sets are from my knowledge of those products, not from a
fresh check of their current versions. API availability claims (`IOAccelerator`
statistics, `ri_diskio_*`, `ProcessInfo.thermalState`, SMC readability) are
well established but were not executed in this session. Treat each as "verify
with a 20-line spike" before building.
