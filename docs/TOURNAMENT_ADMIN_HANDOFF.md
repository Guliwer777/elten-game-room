# Tournament administrator handoff

This snapshot prepares the **official client composition**, not a running
server implementation. `Hub` uses `SharedHub`, which exposes list/create/back
and recovery through context menus. It has no local sandbox, artificial actor,
draft publication menu or owned developer-app selector. Source-only test
adapters remain in the repository; the player stage prunes unreachable
tournament modules and excludes tools/tests/docs.

`ServerWorkspace` targets the same official UUID as `EltenGameRoom.server_app`:
`468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80`. All ordinary table binding, result,
cancellation, continuation and phase reads use that composition. Journals are
scoped by backend identity; no trial records or private credentials are
imported. Access failures do not select a local fallback. `ServerTrialWorkspace`
is a source-only adapter for isolated regression scenarios.

## GitHub review and installer

Submit the maintained application sources, regression tests and contracts in
a pull request. Do not commit installer binaries, local verification reports,
credentials or the optional handoff ZIP. Build a review `.eltsetup` through
`tools/stage-release.rb` and the host package builder. The release author signs
the official installer and distributes it through ELTEN's program catalog.

## Optional offline package contents

- `client/`: unsigned review installer and its exact inventory.
- `schema/`: JSON declaration exported from `ServerSchema` without SDK calls.
- `source/power-games/`: complete application source, runtime resources,
  translations, technical contracts, build tools and regression tests.
- root Polish administrator note and file hashes.

The source tree is for implementation/review and rebuilding; copying Ruby
client classes onto a web server does not create a coordinator. No independent
server daemon, transaction endpoint or notification job is deployed by this
package. Existing public game tables/moves remain LiveSessions.

## Owner deployment

1. Review and sign the official application update; the review installer is
   unsigned. Deploy declarations/permissions for announcements, registrations
   and immutable plan documents using the official owner workflow. They are
   already expressed by `ServerSchema::PROPOSED_TABLES`; do not deploy the
   developer adapter's UUID or import its sample data.
2. Implement a trusted coordinator for playing windows, explicit readiness,
   mutual invitation consent, parallel match occupancy and start notifications.
   It must work while the organizer is offline. Client proposal-notification
   and start-notice contracts are prepared but need trusted backend composition.
   The append-only readiness/proposal observation helpers are not atomic gates.
3. Supply atomic version checks/reservations/start gates and durable operation
   keys: start versus forfeit, completion versus cancellation, and restoration
   versus resolution must have one agreed result. SDK message IDs alone do
   not make table creation idempotent. Confirm uncertain writes without resend.
4. Validate authoritative result/decision lineage against native participants,
   options, history and restored archive boundaries. The client currently
   exports bound ordinary results but is not a tamper-proof authority.
   Only a native table owner can close its session; tournament cancellation
   currently invalidates the sporting fixture without closing a foreign table.
5. Verify cross-computer operation after official deployment. Isolated native
   tests verify client mechanics; they do not replace a deployed end-to-end run.

See `TOURNAMENT_SERVER_INTEGRATION.md`, `TOURNAMENT_PHASE_TRIAL.md`,
`TOURNAMENT_FORFEIT_TRIAL.md` and `TOURNAMENT_SAVED_MATCH_TRIAL.md` for exact
client contracts. Historical trial documents describe experiments, not grants
of production authority. Source test tooling must remain outside player UI.

No credentials, session files, worktree Git metadata or personal runtime
storage are part of the handoff. Packaging does not publish code or deploy
server changes. Server effort should be estimated after reviewing
available transaction and scheduling infrastructure.

## Capacity review still required

The existing direct client result reader limits a view to 64 fixtures and
1000 result-document rows. Standings arithmetic currently accepts at most
256 results; immutable plan documents are limited to 256 KiB. The form's
128 participant ceiling is not a guarantee that every full round-robin
schedule fits these limits. Server-side result projections/pagination and
explicit supported-format limits must be agreed before public rollout.
Do not remove fail-closed budgets without replacing bounded complete reads.
