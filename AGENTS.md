# Kay — Agent Instructions

Kay is Max's push-to-talk dictation app for macOS (see `README.md`). These are the repository-level rules; the global rules in `~/.agents/AGENTS.md` still apply.

## Essential variable

Hold fn, speak, release: the text lands at the cursor and a record is appended to `~/Library/Application Support/Kay/history.json`. Any change executed on that path (key handling, audio capture, the ASR session, paste, the HUD shown during dictation) is core-path, however cosmetic it looks.

Read this variable from the product, never from a proxy: a `history.json` entry newer than the install, and no new `~/Library/Logs/DiagnosticReports/Kay-*.ips` since the install. Signing, notarization, the DMG, Sparkle installing the update, idle CPU, and offscreen renders do not read it.

## Release policy (Max's decision, 2026-10-07)

`make release` notarizes, publishes the GitHub release and `appcast.xml`, and installs the build here. There is no waiting gate and no minimum-dictation rule before installed copies are offered a version: Max is the first user of every release and will report a broken one. In exchange, after every install read the passive signals above before any success claim and before stacking another release on top; say "changed, unverified" until a post-install dictation is in `history.json`. `macOS/scripts/publish.sh --dry-run` checks the preconditions without spending a notarization.

## Recorded failure classes

- **HUD animation versus panel resize** (1.3.1 on 2026-09-30, again 1.4.4–1.5.2 through 2026-10-02): a SwiftUI animation in the HUD collided with the floating panel changing size in the same constraint pass, and every dictation crashed for 27 hours while verification looked only at proxies. The fix was structural (fixed-size panel, 1.5.3); the retrospective is `~/AI/2026/1002-Kay崩溃复盘.md`. Read it before changing the HUD, the panel, or anything on the dictation path.
- **Quitting while a dictation lands** (2026-10-07): the install script quit Kay 0.9 s after a key release and the text was lost. Since 1.5.4 Kay waits for the dictation to land (up to 60 s) before quitting and the installer waits for the process to exit; this protection runs only on the next install and was unverified when recorded.

- **Core Audio hanging the main thread at recording start** (2026-10-09, 1.6.0): with a Studio Display attached, AVAudioEngine's input node first attached to the system default input, Core Audio refused it (`'nope'`, a duplicate property listener), and AVAudioEngine looped in `GetHWFormat` on the main thread until a force quit. No crash report; the evidence is in `~/Library/Logs/Kay/incidents/2026-10-09-main-thread-hang/`. Since 1.6.1 the microphone is an AUHAL unit set to the chosen device before it initializes, started off the main thread with a 2 s limit, then the built-in microphone; `HangWatchdog` snapshots any main-thread stall during a dictation into `~/Library/Logs/Kay/hangs/`. Read those, and `~/Library/Logs/Kay/kay.log`, before changing audio capture.

## Working rules

- Max uses the installed `/Applications/Kay.app`; `build/Kay.app` is only the release pipeline's input. Do not test by launching the build copy as if it were what Max runs.
- Do not steal focus, change settings, or interrupt an active dictation while Max is working. If that leaves a core-path change unverifiable, put the conflict first in the report and let Max choose a test window; do not substitute an easier check.
- Local test and check suites are not run here.
