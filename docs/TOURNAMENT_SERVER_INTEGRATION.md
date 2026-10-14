# Tournament server integration

The official client entry point is `SharedHub`, composed with `ServerWorkspace`.
It targets the same application UUID as `EltenGameRoom.server_app`. Local trial
adapters are retained for regression tests and are excluded from the player
installer. They do not grant production authority.

## Owner declaration and authentication

Use the official application owner and the supported ELTEN launcher/SDK stamp
flow. A `stamp_required` response does not establish whether a table exists.
`ServerSchema::PROPOSED_TABLES` is the source of the table declaration;
`tools/tournaments/export-server-schema.rb` exports it without network writes.
Declaring tables in client Ruby does not deploy or migrate server tables.

- `tournament_announcements`: immutable publication identity, title, game,
  rules, settings, registration dates and timezone metadata.
- `tournament_registrations`: authenticated append-only join, withdrawal,
  organizer removal, pairing, amendment and cancellation events.
- `tournament_plan_documents`: bounded immutable schedule, phase, binding,
  readiness, consent and result documents interpreted by their client contracts.

The SDK insertion author, ordered IDs and timestamps remain authoritative.
Review nullable columns, access policies and 2048-byte field budgets before
owner deployment. Account names supplied in a payload are not authentication.

## Independent coordination

Publication tables and notification delivery do not provide atomic tournament
coordination. A trusted service must operate while the organizer is offline and
validate playing windows, explicit readiness, mutual consent and occupied seats.
It needs atomic version checks, reservations and durable operation keys for
creation/start, completion/cancellation and restoration/resolution. Current
append-only observation helpers and local file ports do not supply those gates.

The client uses native LiveSessions tables and the existing game executor.
A fixture binds its actual native table, session, participants, options and
accepted history. Return legs reverse the first-leg seat order. Both players
must accept a return; postponing leaves its scheduled fixture pending.

Saved-match continuations preserve fixture identity and validated archive
lineage. Sporting cancellation preserves native history and invalidates late
results; it does not close a session owned by another account. Server validation
must enforce these boundaries against a modified client.

## Notifications and recovery

The client prepares global app-notification presentation through the supported
host API. Verified proposals expose Play/Not now, or Return/Not now. Enter on
details cannot accept. A start notice is informational and does not imply
readiness. The host UI presents notifications; bounded worker operations only
prepare or validate copied data. Do not add another client polling scheduler.

Uncertain writes remain journaled and are reconciled read-only before retry.
An empty or failed read is not proof of absence. Local duplicate protection is
not server-wide idempotency or exactly-once table creation.

## Deployment acceptance

After owner deployment, verify real independent accounts on two computers:
publication/enrollment, consent/refusal without premature table entry, normal
and return seat order, authoritative results/standings, saved-game continuation,
cancellation, lost acknowledgements and operation while the organizer is offline.
Isolated client tests do not establish a deployed server coordinator.

See [administrator handoff](TOURNAMENT_ADMIN_HANDOFF.md) for remaining owner
work and capacity limits, and the phase, forfeit and saved-match contract notes
linked there for exact client boundaries.
