# Persisted history and alerts — design

Status: proposal, nothing implemented. Follows `docs/audit/2026-10-13-information-gaps.md`
items #5 (alerts) and #6 (history).

## Why these two together

Alerts need a memory ("CPU has been above 90 % for five minutes") and history
needs a reason to exist beyond a chart. Both need the same thing the app does not
have today: sampling that continues when no window is open.

## The decision that shapes everything

Sampling today is demand-driven and **stops entirely when nothing is displaying
metrics** (README, *Sampling*). History and alerts contradict that unless the
user opts in. Proposal:

- A new scope, `.background`, retained only while *History* or *Alerts* is
  switched on in Settings. Both default **off**.
- While retained, the loop samples every **10 s** (never faster, whatever else is
  on screen), cheap collectors only — CPU, memory, network totals, GPU, thermal
  state, battery. No process walk.
- Turning both off releases the scope and the app returns to today's behaviour:
  zero sampling with nothing on screen.
- The Settings copy says plainly: "MyMac keeps sampling every 10 seconds while
  this is on."

Rejected: always-on sampling. It breaks a documented promise and costs idle CPU
for people who never asked.

Consequence worth stating: history has gaps wherever the app was not running or
the Mac slept. Charts show gaps as gaps, never interpolated.

## History

**Resolution tiers** (downsampled by averaging, max kept alongside for spikes):

| Tier | Step | Kept | Points |
|---|---|---|---|
| Recent | 10 s | 1 hour | 360 |
| Day | 1 min | 24 hours | 1 440 |
| Week | 10 min | 7 days | 1 008 |

**Series:** CPU, memory used fraction, network down/up, GPU, disk read/write,
battery charge, thermal level. About eight series — a few hundred kilobytes in
total.

**Storage:** one JSON file per tier in `~/Library/Application Support/MyMac/`,
written atomically, at most once a minute and at quit. No database: no new
dependency, trivially inspectable, and deleting the folder resets it. A
"Clear history" button sits next to the switch. Corrupt or unreadable files are
discarded, not repaired.

**Layering:** a `HistoryStore` actor in `MyMacCore` that takes samples and
returns series for a range; the file location is injected so tests use a
temporary directory. The UI never touches files, and `MyMacCore` still imports
neither AppKit nor SwiftUI.

**UI:** no new section. One range control (Live / 1 h / 24 h / 7 d) at the top
of the CPU, Memory, Network and Battery pages; "Live" is today's sparkline.
The dashboard is unchanged.

## Alerts

**Built-in rules** (fixed set, no rule builder):

| Rule | Fires when | Clears when |
|---|---|---|
| Sustained CPU | total usage ≥ 90 % for 5 min | below 70 % for 1 min |
| Memory pressure | pressure is High for 2 min | pressure drops to Moderate or lower |
| Low disk | available < 10 GB (or < 5 %) | back above, with 10 % margin |
| Hot Mac | thermal state Serious or Critical for 1 min | back to Warm or lower |
| Battery wear | health < 80 % | evaluated once per day, fires once |

Per-process alerts already exist in `ProcessWatcher` (sustained CPU, memory
growth) and stay in the Processes page; they are not notified in this phase.

**Behaviour:** hysteresis on every rule (separate fire and clear thresholds) and
a cooldown of 1 hour per rule, so a value hovering at the line cannot spam. The
rule logic is a pure function `(rule state, new sample) -> event?` in
`MyMacCore`, tested with scripted sample sequences — no clock, no
notifications.

**Delivery:** `UserNotifications`, requested **only when the user first turns
Alerts on**, from that button press. Denied permission is shown in the card, not
retried. A fired alert also marks the menu bar item (tint) so it is visible
without notifications.

**Settings:** one card, "Alerts": a master switch and one switch per rule, all
off by default. Thresholds are not exposed in this phase; adding
"Advanced" later is cheap and a rule builder is deliberately out of scope.

## Compatibility

Everything above is architecture-neutral: it consumes values the collectors
already produce. The only per-chip dependency is GPU, which is simply absent
from history where the driver reports nothing.

## Risks to check before building

1. **Notifications from an ad-hoc signed, `LSUIElement` app.** Expected to work
   with a bundle identifier but unverified; a 20-line spike decides it. If it
   fails, the fallback is the menu bar tint plus an in-app list.
2. **`UNUserNotificationCenter` requires a bundle** — it must not be touched in
   `swift test`; inject a `NotificationSink` protocol.
3. **XCUITest idling.** Background sampling must stay frozen under
   `-MyMacUITesting YES`, as the foreground loop already is.
4. **Sleep/wake.** Time jumps after wake must not count as "5 minutes of high
   CPU"; rule timers use sample timestamps and reset on a gap larger than 3×
   the step.
5. **README and CLAUDE.md** state "sampling stops entirely when nothing is
   displaying" and "nothing is requested at launch" — both stay true only with
   the opt-in design above, and the docs need the qualifier.

## Build order

1. `HistoryStore` + tiers + tests (pure Core).
2. `.background` scope, Settings switch, wiring to the store.
3. Range control on CPU / Memory pages, then Network / Battery.
4. Alert rules + tests, then notification spike, then delivery and Settings card.

Each step ships on its own and is useful alone.

## Open questions for the owner

- Is a 10 s background sample acceptable, or should it be 30 s?
- Should "Hot Mac" and "Low disk" be on by default once Alerts is enabled, or
  should every rule start off?
- Keep 7 days, or is 24 hours enough?
