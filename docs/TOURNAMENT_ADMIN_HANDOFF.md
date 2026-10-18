# Tournament administrator handoff

## Current integration

`Hub` opens `SharedHub` with `ServerWorkspace`, using the same application as
ordinary Power Games: `468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80`.
Player menus contain no virtual-account selector, local sandbox or diagnostic-app
selector. Release staging excludes unreachable trial modules and test tools.

The owner-approved declarations for `tournament_announcements`,
`tournament_registrations` and `tournament_plan_documents` have been created on
the official application. Existing tables, protection and file limits were not
changed. A Ruby declaration is not itself deployment:
`tools/tournaments/export-server-schema.rb` exports it without network writes.

Live development trials use a separate application,
`90be3253-dc66-447d-b8c5-ada31b984b04`, with separate accounts and records. Its
owner-approved private-file allowance is 1 MiB per account for saved-game tests.
Do not copy its UUID, unprotected test policy or records into production.
Journals are scoped by backend identity and cannot migrate implicitly.

## What works without a new server service

The client implements publication, enrollment, shared schedules, ordinary table
invitations, match entry, results, return matches and series through the existing
API. Players use the ordinary invitation controls, without a separate readiness
screen. Tournament matches cannot be saved or resumed from private archives;
ordinary non-tournament saves retain their existing behavior.
Participants can coordinate an existing schedule while its organizer is offline.
A new server-side coordinator is not a prerequisite for this workflow.

The server authenticates writes and orders records, but does not execute the
application's validation code. Reservations select the first visible complete
claim; they are not atomic transactions covering session creation. Modified
clients and network partitions can violate guarantees that require trusted
server logic. Do not advertise complete anti-cheat protection or exactly-once creation.
See [server integration](TOURNAMENT_SERVER_INTEGRATION.md).

## Before a public release

1. Review the final sources and affected regression results. Preserve initial
   failures and distinguish stale test fixtures from product defects.
2. Verify the player stage contains the shared server entry point and no local
   test menus or diagnostic credentials. Build and sign only at the owner's
   request. Packaging does not publish code or deploy server changes.
3. Check protected-table access through the signed application and normal
   launcher. An unsigned diagnostic load does not establish production access.
4. Preserve capacity limits: default 16 participants, at most 256 matches per
   phase, 256 KiB per plan document and bounded complete paginated reads.
5. Run a two-computer trial as a separate network check. Four accounts on one
   computer exercise accounts, permissions and game flow, not independent links.

Commit maintained source, tests, translations and contracts, not installers,
private logs, profiles, session data or credentials. Historical trial documents
describe experiments, not current deployment requirements or production
authority. Existing phase, forfeit and saved-match notes supplement the current
server contract where applicable.
