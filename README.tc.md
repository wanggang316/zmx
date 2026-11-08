# codans zmx Fork

This fork is based on the upstream `v0.6.0` tag and maintained on the
`v0.6.0-tc` branch.

- **Fork URL:** https://github.com/wanggang316/zmx
- **Upstream:** https://github.com/neurosnap/zmx (`v0.6.0` tag)

## Purpose

codans runs every pane as `zmx attach <session>`, so a pane survives an app
restart. The patches below let the app spawn and restore sessions, watch them
without a terminal, and keep pane state correct across a detach.

## Carried Patches

- `feat: add serve subcommand + Snapshot IPC + restore-from` — `zmx serve`
  spawns a daemon and exits; the `Snapshot` IPC tag writes the serialized
  terminal state to a file that `attach --restore-from` replays.
- `feat: print daemon PID alongside socket path in serve`
- `feat(zmx): parse --restore-from in the attach arm`
- `test(zmx): add restore.bats real-zmx restore integration suite`
- `fix(serialize): unwrap scrollback so restored sessions reflow to width`
- `fix(daemon): keep the session alive when a terminal resize fails`
- `feat(daemon): add a read-only observer protocol` — `Observe` /
  `ObserveState` / `ObserveResize` IPC tags.
- `feat(daemon): hand the lead to the most recently active client` — `Claim`
  IPC tag.
- `fix(daemon): close every inherited descriptor, not only the first 64`
- `feat(daemon): answer the OSC 7501 support query while detached`
- `fix(daemon): answer terminal queries again once every terminal detached`
- `feat(daemon): replay the OSC 0/2 title on attach` — the daemon keeps the
  last non-empty OSC 0/2 title (`Daemon.last_title`; an empty title does not
  erase it, ADR 0009 decision 4). On a re-attach, `handleInit` sends it as
  `OSC 2` after the serialized terminal state, only to a client that sent
  `.Init`. A pane then shows the program's title at once after an app
  restart. See codans ADR 0009, decision 8.
- `fix(daemon): keep the last non-empty title across an empty title` —
  follow-up to the patch above: the terminal drops its title on an empty
  OSC 0/2, so the daemon records the title after each PTY chunk instead.

## Upgrading

Rebase the carried patches on the new upstream tag one at a time, on a new
`<tag>-tc` branch. Drop a patch when upstream has the same behavior.
