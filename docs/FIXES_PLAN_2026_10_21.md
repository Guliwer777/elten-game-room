# Power Games fixes plan — 21 October 2026

Agreements from 21 October 2026. Status: changes implemented with targeted
offline checks and the scoped live-application trials completed. The followup
covered administrative settlement for every selected small-point game and
short-target normal matches, including both Rummy score directions. Retain
the evidence limits below; this is not proof of every possible game variant.
This is a new scope; earlier completed fixes plans remain unchanged.

The maintainer suspended live/server testing later on 21 October because of
a suspected ELTEN server outage. Continue source work and isolated offline
tests continued during that pause. After the server returned, the maintainer
requested verification through all relevant paths in the actual running
application on live accounts, not only direct model/service calls. Keep the
earlier partial trials separate from this end-to-end coverage. Do not
interpret the pause as successful completion of pending live coverage.
The local evidence and outstanding trials are recorded in the Git-ignored
`tmp/fixes-20261021/README.md`. The maintainer subsequently authorized a
signed release as version 2.0.5.4 with a new build, an updated changelog and a
GitHub push after verification. Release preparation is now in scope.

The changes cover explicit game support for tournament small points, technical
scores for supported forfeits, an organizer decision awarding no points to
any participant, and removal of the condition that hides otherwise available
small points. Organizer settlement must also cover the complete multiplayer
order, rather than requiring a single winner or loser to determine every
other participant's result. These changes do not alter ordinary game rules
or the tournament points formula for ordinary wins, losses and shared places.
An explicit forfeit is an exception: a forfeiting unit receives zero
tournament points, including when several forfeiting units share a place.
Manual settlement must not interrupt active play or eliminate a participant
from a running game. Disconnection during play belongs to the existing
automatic five-minute absence mechanism.

The plan also includes a table-level shortcut for creating and joining an
ELTEN voice conference, with invitations presented inside Power Games and
no automatically opened dialog during play.
It also standardizes the default bot decision delay at one second across
all games, rather than only selected games.
Countries and Cities will drop Surname, Chemical element, Building and
Invention, and replace Famous person with Known athlete. The selected new
categories are Drink, Tool, Known actor, Known writer and Known athlete.
Investigate the reported progressive Mahjong slowdown over successive hands.

## 1. Selected games and score direction

Use the games from the first proposed table, not the unrelated list of games
that currently export scores. Support must depend on a game declaration and
its options. All other games have tournament small points disabled.

The technical scores below are written as winner versus losing opponent.
They describe the target-based proposal for a terminal two-sided forfeit, not
a rule awarding an entire match to every remaining multiplayer participant.

| Game | Small points | Proposed technical score |
| --- | --- | --- |
| Axel Pong | Higher is better | Configured point target to zero, for example 11:0 or 21:0; unlimited games use 11:0. |
| Audio Ball | Higher is better; sum points across all sets | Each required winning set is 7:0: totals of 7:0, 14:0 or 21:0. |
| 1000 miles | Higher is better; cumulative game points, not miles | Configured target to zero; default 5000:0. |
| Thousand | Higher is better | Configured target to zero; default 1000:0. |
| Cat, head, tail | Higher is better | Configured target to zero; default 100:0. |
| Farkle | Higher is better | Configured target to zero; default 1000:0. |
| Countries and Cities | Higher is better | Configured target to zero; default 50:0. |
| Spades | Higher is better | Configured target to zero; default 300:0. |
| Quiz | Higher is better | Configured target to zero, for example 15:0. |
| UNO | Lower is better; penalty points | Zero versus the configured elimination limit; default 0:500, not 500:0. |
| Rummy, normal scoring | Higher is better | Configured target to zero; default 1000:0. |
| Rummy, elimination scoring | Lower is better; penalty points | Zero versus the configured elimination limit; default 0:500. |
| Domino | Lower is better; penalty points | Zero versus the configured limit; default 0:100. |
| Mexican Train | Lower is better; penalty points | Zero versus the configured limit; default 0:100. |
| 99 | Higher is better; remaining tokens | Configured starting token count to zero; default 9:0. |

The selection includes Axel Pong and the other thirteen games. Rummy has two
rows because its score direction depends on its variant. Do not drop or add a
game merely to match the earlier conversational count of thirteen.

Bridge, 3-5-8, Mahjong, Reversi and Taboo are outside this selection even though
their current adapters can export numeric results. Their tournament small
points must be disabled under the new policy. Do not extend the selection to
Scrabble, Yahtzee, Biblios, Mancala or other games using invented fixed scores.

## 2. One shared small points mechanism

- Add an explicit game-owned declaration of tournament small-point support,
  including enabled or disabled status and higher-is-better or lower-is-better
  order. The base declaration is disabled; variants may change the policy.
- Reuse the existing tournament result and score-export hooks. The game owns
  its score units, real result export and target-based technical-score inputs;
  the shared tournament layer owns validation, aggregation and presentation.
- Do not introduce a second result engine or separate game-ID switches in the
  UI, standings, forfeits or result reader. A future game opts in through the
  same contract without editing an allowlist in those layers.
- Export real final scores for every selected game, including games that do
  not export them today. Reuse public participant/team scores and collapse a
  repeated team total once, rather than summing it for every team member.
- Apply the declared direction consistently to score comparisons, score
  differences and any small-point tie-break. UNO, Domino, Mexican Train and
  elimination Rummy must not inherit the default higher-is-better assumption.
- Disabled games do not contribute small points or use them as a tie-break,
  under the new policy, even if their adapters can export numeric scores.
  Preserve historical document verification and the already finished
  classifications under their original policies as described in section 6.
- A failed export from a game declaring support is an error or unavailable
  data, not permission to silently disable support or replace scores with zero.
- Preserve the existing ordering and large-point formula: two points per
  opponent placed below, one per opponent sharing the place, zero per opponent
  placed above. A team remains one competitive unit.
- Apply an explicit forfeit override after that calculation: every unit
  marked as losing by forfeit receives zero tournament points, regardless of
  shared places or earlier eliminations. Remaining units still receive their
  normal placement-based points. Ordinary shared-place results without a
  forfeit keep the existing formula.
- Keep this override separate from the all-participants-zero decision. For
  example, one first-place attendee and three joint-second-place forfeiting
  participants receive 6, 0, 0, 0, not the ordinary shared-place 6, 2, 2, 2.
  The explicit all-participants-zero decision instead gives 0, 0, 0, 0.

## 3. Forfeits and technical small points

Use the shared score policy for organizer settlements and automatic absence
results, while keeping their authority and lifecycle boundaries separate.
Do not change the five-minute absence allowance or host selection. Technical
scores are explicitly administrative scores, not a fabricated normally
completed replay, deal, set or event history.

### Manual settlement outside active play

- Every game must allow the authorized organizer to settle an unresolved
  fixture outside active play. Missing continuation support, a missing scoring
  checkpoint or disabled small points must not produce a game-specific refusal
  to award a forfeit there.
- Do not offer manual termination of an active match or the manual action
  "eliminate this participant and let the others continue" as forfeit options.
  Hide these actions in the UI and enforce the same boundary in the service.
  The all-participants-zero option must not become another way to stop a
  running match.
- A never-started fixture remains eligible even if its waiting table already
  exists. Distinguish a created table from an accepted game start. A finished
  but unresolved fixture can be settled only without overwriting a confirmed
  result or pretending that its game is still running.
- Replace those unsupported-game refusals with the shared administrative
  settlement flow. Verified scores may suggest places, but are not a mandatory
  dependency for an eligible organizer decision. Missing scores remain
  unknown; do not invent an actual completed round to justify the decision.
- Missing native history is not proof that a bound match never started or
  stopped running. Verify its lifecycle through the authenticated existing
  bindings and start/result evidence. Reconcile uncertain state rather than
  interrupting a potentially active game or reporting an unsupported game.
- Organizer authority, authenticated fixture identity, existing result
  protection and fresh write-boundary checks remain mandatory. Unavailable
  server authorization/result reads mean an unconfirmed operation to reconcile,
  not permission to bypass checks or claim that a forfeit has been stored.
- The rule applies to two-sided, multiplayer and team matches independently
  of game-specific scoring hooks, within the non-active lifecycle boundary.

### Automatic absence during play

- Leave disconnection during a running game to the existing automatic
  five-minute allowance and its authenticated native presence history.
  Do not add an organizer button that bypasses or shortens that allowance.
- After the allowance is exhausted, use the game's existing validated
  elimination/continuation or terminal-result behavior. If the remaining
  participants can continue, they determine their places through play;
  otherwise the automatic mechanism resolves the match under its agreed rules.
- Place the automatically removed participant behind those who complete the
  game without forfeiting and award that participant zero tournament points.
  Earlier automatic removals must not earn points merely by comparing their
  elimination order or shared places with other forfeiting participants.
- For a selected higher-is-better game, the removed participant receives
  zero technical small points. For a selected penalty-point game, reverse
  that losing result: use the configured penalty/elimination limit, such as
  500 in default UNO or 100 in default Domino and Mexican Train. Rummy follows
  its selected variant. Do not give a penalty-game forfeiter the favorable
  zero score. Games outside the selection still have no small points.
- If play continues, keep the remaining participants' actual final small
  points; do not rescale them or award a fresh full technical victory to each.
  The removed participant's technical result is counted once, not added to
  their partial score. A two-sided match ended by absence uses the declared
  two-sided technical result. For a terminal multiplayer absence, retain the
  existing authenticated determination of the remaining places and scores,
  with the explicit losing-unit override above.
- Automatic elimination and any resulting end of play remain part of absence
  handling, not selectable manual forfeit actions. They must still use the
  shared small-point capability and agreed technical-score policy.
- Preserve the existing presence safeguards: an inactive window, quiet player,
  transport error or failed membership read is not confirmed disconnection.
  Preserve the cumulative allowance and existing return/host-transfer rules.

### Full multiplayer settlement

Choosing one winner or one loser is not sufficient to resolve a multiplayer
match. Extend the existing organizer flow rather than creating a second
standings editor or asking the organizer to modify raw server records manually.

The forfeit interface must remain easy to use, not merely technically complete.
For two competitive units, keep the losing-side/all-zero choice short. For
multiplayer settlement, use one clearly labelled list of players or teams,
editing the selected unit with the usual keyboard controls and showing the
complete consequences before confirmation. Show small-point fields only for
supported games, with valid suggestions already filled in. Avoid a chain of
separate dialogs for every participant, raw identifiers, duplicate controls
or a form that requires understanding the storage protocol. Verify the native
form's actions, labels and return after cancellation on live accounts through
MCP, as well as the resulting points. The maintainer excluded keyboard-use
testing; do not simulate keystrokes or run dedicated keyboard trials.

- Let the organizer determine the complete final order of all original
  competitive units, including shared places, and identify participants
  losing by forfeit. A team is one row, not separate decisions for its members.
- In small-point-enabled games, let the organizer enter and confirm the
  administrative small-point result for every unit. The game can prefill its
  target-based technical suggestion, but the organizer can adjust the result
  within the shared numeric/unit validation. Do not impose a proportional
  conversion from places, such as 300, 200, 100, 0 for four participants.
- Keep tournament points calculated by the shared placement/forfeit rules,
  rather than making them independent editable numeric fields. The organizer
  controls places, forfeit status and supported small-point values; excluded
  games have no small-point entry controls.
- Offer a complete administrative settlement even when no game result or
  checkpoint can supply the order, provided the fixture is not actively being
  played. If verified game data exists, use it as a proposal for review rather
  than a hidden, mandatory ordering rule.
- Represent shared places as ordered groups and derive competition places
  from those groups: 1, 1, 3, 4 or 1, 2, 2, 4. Do not accept duplicated units,
  omitted participants, unsupported place gaps or accidental arbitrary ordering
  within a shared place.
- Do not ask the organizer to forecast the eventual places of players who
  are still playing. An active match stays outside this manual settlement
  flow; the automatic five-minute absence mechanism handles a missing player.
- Keep "All participants receive 0 points" as a separate explicit choice,
  not a shared-last-place workaround that could award draw points.
- Before confirmation, display the full order, shared places, forfeit
  decisions, tournament points and any agreed technical small points for every
  unit. Distinguish the organizer's entered small-point result from the
  automatically calculated tournament points and from actual game history.
- Revalidate the exact confirmed decision and non-active lifecycle before
  writing. A newly accepted game start, a game result, changed participant
  boundary or prior settlement must invalidate a stale preview. A valid
  administrative resolution prevents a later start or conflicting result for
  that fixture; it must not cancel an already running game.
- Several units can lose by forfeit in one administrative decision. They may
  share a trailing place, but each receives zero tournament points rather than
  earning draw points from the other forfeiting units. Preserve verified prior
  automatic eliminations and apply the same zero-point rule to those units.

### Shared result safeguards

- Retain the authenticated original result, decision, binding and game
  settings. Keep actual game scores distinguishable from technical scores.
- A supported two-sided terminal forfeit uses the game's declared technical
  result as the default administrative suggestion and as the automatic
  absence result. Manual small-point adjustments are explicit organizer input,
  not reconstructed play. The contribution is counted once, with the same
  units and direction as a normal result; never add it on top of the result
  it replaces.
- If small points are disabled, a forfeit still awards the existing tournament
  points and places but does not invent a numeric game result.
- Preserve the multiplayer distinction inside automatic absence handling:
  eliminate and continue when supported, otherwise resolve under the existing
  automatic terminal policy. Do not expose either operation as a manual
  interruption action. Never turn one player's absence into several
  independent full-match victories without an agreed scoring rule.
- Keep organizer-only authorization, read-only preview, explicit confirmation,
  fresh validation before writing, immutable operation identity and recovery
  of uncertain writes. A changed preview needs confirmation again.

## 4. Organizer decision awarding zero points to everyone

Add an explicit option to the existing forfeit flow, with wording equivalent
to "All participants receive 0 points". The organizer can choose it instead
of selecting a single losing participant, for example when nobody played.
Do not require choosing a fictitious loser or winner for this option.
It shares the manual settlement boundary: it cannot stop an active match or
replace the automatic five-minute disconnection mechanism.

- It closes the selected fixture administratively, so it no longer waits for
  play and cannot be awarded or started a second time.
- Every participant or team receives zero tournament points. There is no
  winner, shared first place or sporting draw, and no technical small-point
  bonus or penalty is added for this decision.
- Distinguish an explicit zero contribution from unavailable game scores.
  Do not fabricate an ordinary 0:0 result or overwrite any real score history.
- The confirmation lists all affected participants and clearly states that
  nobody receives points. Preserve already recorded results and the normal
  organizer checks; concurrent result publication must invalidate a stale
  confirmation rather than overwrite that result.
- Give this decision an explicit, versioned result meaning. An empty winners
  list alone currently means a draw and would incorrectly award points. Do
  not encode the new outcome by reusing that ambiguous representation.
- Update standings, match status, completion, retention/progress and notices
  to recognize the administrative resolution without inventing a win or draw.
  It is a resolved fixture, not a successfully played match. Keep these facts
  distinct in counters and presentation.
- In a knockout match closed with zero points for everyone, nobody advances.
  The next opponent receives a bye. If this is the final, finish the tournament
  without a winner. Propagate empty bracket positions explicitly; do not
  advance an arbitrary player, invent a champion or leave the fixture pending.
- Verify round-robin and group completion separately. The no-award outcome is
  a resolved fixture with zero contributions, not a draw or an unfinished game.

## 5. Show supported small points without the current hiding condition

Remove the presentation requirement that `scored_matches == played` before
small points can appear. A forfeit or another missing score must not hide the
verified totals from the participant's other matches.

- The game declaration determines whether small points are shown at all.
  Disabled games have no small-point fields or small-point tie-breaks.
- For enabled games, show available verified totals even if other resolved
  fixtures have missing scores. A zero is a valid number, not a missing value.
- When necessary, briefly distinguish partial totals from complete totals;
  report unavailable data rather than substituting zero for an unknown score.
- Explicit no-points administrative results contribute nothing and do not
  make otherwise complete totals appear unavailable.
- Do not confuse display with permission to rank by incomplete data. Keep
  numeric tie-break safety separate: incomplete or incomparable actual scores
  must not silently decide a sporting tie. Declared technical results can
  provide the missing verified contribution once their policy is settled.
- Cover current standings, completed tournaments, phase results, confirmation
  previews and every other shared score presentation. Refresh silently while
  preserving selection, focus and already displayed valid data on read errors.

## 6. Existing tournaments and result compatibility

- Do not delete, recreate or overwrite tournament tables, publications,
  bindings, plans or result documents. No schema, protection or quota change
  is authorized by this plan.
- Keep old receipts verifiable under their original result policy. The new
  declaration must not change canonical options or rehash an existing match.
- Separate improved presentation of existing verified scores from applying
  new technical-score rules retrospectively. Show the available real small
  points in old tournaments without retroactively adding technical scores to
  their old forfeits or changing already finished classifications. Do not
  fill historical unknown values from current game defaults.
- Retrospective changes to finished tournament scoring require a separate
  explicit maintainer request. The current plan does not authorize rewriting
  old receipts, backfilling technical scores or reordering completed standings.
- New zero-award results must never be mistaken by an older result reader for
  a draw, an ordinary victory or permission to replay the same fixture.

## 7. Voice conversation at the table

Make it easy for people already playing together to start a voice
conversation without leaving the table. Reuse ELTEN's Conference API for
audio and channel management; Power Games supplies the table button and
invitation, not another voice service.

- Add a button at the table labelled "Rozmowa głosowa" in Polish. When no
  conversation is available, activating it opens a minimal channel-creation
  form: an automatically suggested name, public/hidden visibility and an
  optional password. Leave other audio settings at the native defaults.
- After successful creation, announce the invitation once inside Power
  Games, for example "Papierek zaprasza do rozmowy głosowej". Do not send a
  separate native ELTEN conference invitation or confuse this action with
  a table-membership or tournament-match invitation.
- Show a persistent "Dołącz do rozmowy" button at the table while the channel
  is available, including to people who missed the announcement or arrived
  later. Use the existing channel rather than creating a second one. Handle
  simultaneous creation attempts without advertising duplicate conversations.
- Never open an invitation dialog automatically during play or move focus
  to the button. A brief announcement and the available button are the
  invitation. Creation and any necessary confirmation dialogs open only
  after the user's deliberate action.
- Joining is optional. If the user is already in another conference, ask
  before switching. Preserve their microphone and push-to-talk preferences;
  do not force the microphone on. Joining must not leave the game table,
  stop its execution or discard chat drafts and selection.
- In the inspected native API, non-public means hidden, not automatically
  restricted to table members. Describe that distinction accurately and use
  the native password protection where requested. Do not place passwords in
  public game history or discovery metadata.
- Scope the invitation to its table and channel identity. If the channel
  becomes unavailable or the table changes, reconcile the button rather than
  leaving a stale join action, repeatedly announcing the invitation or
  silently creating another channel. Failure to create or join must leave
  the game usable and must not claim success.
- Integrate through the existing shared UI and event-driven table framework,
  preserving silent refresh, keyboard navigation and normal background game
  progress. Do not introduce another polling loop or game-specific copies of
  the voice controls.

## 8. One-second default bot delay everywhere

- Set the default bot decision delay to 1 second in every game and variant,
  including bot actions in Duck Racing challenges. Do not apply this default
  only to a selected group of games.
- Use the existing shared setting and execution mechanisms. Remove conflicting
  game-specific defaults or bypasses that make a bot ignore that setting;
  do not add a second bot scheduler or duplicate timing logic in each game.
- This is a default, not a fixed mandatory delay. Preserve explicitly chosen
  values and do not overwrite existing user settings merely to apply the new
  default. Ordinary and tournament play use the same default.
- Apply the delay to bot decisions through the existing timing contract,
  without blocking the UI or adding sleeps to realtime physics/input loops.
  Do not change movement speed, shot cadence or other game-rule timing as a
  side effect of standardizing the decision-delay default.

## 9. Countries and Cities categories

Agreed removal from the categories offered for new rounds: Surname,
Chemical element, Building and Invention. Remove them from the built-in
pools and the custom selection, not merely from the default pool.
Also replace Famous person ("Sławna osoba") with Known athlete
("Znany sportowiec") in those same selections.

Selected replacements:

- Drink ("Napój"): for example coffee, lemonade or compote.
- Tool ("Narzędzie"): for example a hammer, saw or drill.
- Known athlete ("Znany sportowiec"), replacing Famous person.
- Known actor ("Znany aktor"), including actresses.
- Known writer ("Znany pisarz"), including women writers.

These replace the earlier, unapproved Fictional character and Game proposals.
Do not retain the broader Famous person category alongside the actor, writer and athlete
categories. Keep category names short and their accepted scope clear, using
natural labels in every supported language. Update the affected pools and
their descriptions together.

Preserve existing category IDs and stored mask meanings when reading old
games and already drawn rounds. Do not shift historical mask positions or
rename a stored Surname answer into a new Drink answer. New categories must
have their own identities; removing old choices must not corrupt saved
games, tournament options or a round already in progress.

## 10. Mahjong slows down over successive hands

Reported symptom, not yet reproduced or measured: in Hong Kong play with
bots, the game becomes progressively slower by approximately the third or
fourth hand. Bot actions increasingly lag behind the human player's desired
pace. The exact client/build, bot count and timings are not supplied.
Do not present this report as a confirmed cause, leak or completed fix.
This bug is independent of the user-configurable bot delay and its proposed
one-second default. Investigate and fix the unintended growth separately;
changing that setting does not count as fixing the slowdown.

- Reproduce several consecutive hands at the same table without restarting
  the game. Cover at least four complete Hong Kong hands with a human and
  bots, recording the first-hand baseline and later-hand timings. A check
  that merely starts a second hand is not sufficient to exclude this report.
- Keep the configured bot delay constant. Measure separately the intentional
  delay, scheduling/queue wait, bot calculation, state reconstruction/copying,
  presentation and network/write latency. Compare similar decision types;
  do not mistake a more complex individual hand for history-dependent growth.
- Inspect history-dependent work and the lifecycle of per-hand resources:
  accepted events and spoken history, incremental-replay fallbacks, snapshot
  copies, candidate/scoring calculations, retained callbacks/tasks and memory
  pressure. Check that opening another hand does not multiply executors or
  leave pending work from the previous hand.
- The source already uses the shared executor, a replay-only strategy and
  incremental replay. Do not prescribe adding them as though they were
  missing. Potential costs still include copying accumulated accepted events
  and history, rebuilding the seen-event index and copying the replay for
  planning/presentation. These are investigation targets, not measured causes.
- The inspected `test/games/mahjong/match_runner_test.rb` plays the first MCR
  hand and starts the second; it is not a Hong Kong third/fourth-hand timing
  regression. Add coverage of the reported long-running path rather than
  claiming that existing short progression checks already cover it.
- Fix a reproduced cause at the responsible shared or game-owned layer,
  preserving existing bot strategy, legal-action checks, deterministic replay,
  complete history, saved games, host transfer and private-card boundaries.
  Do not hide slowdown by reducing bot strength, truncating accepted history,
  skipping validation or changing the chosen delay.
- Compare before/after costs with the same workload, and record any remaining
  growth rather than claiming constant-time operation without evidence.

## 11. Verification for the affected changes

Use targeted local regressions and later live trials for the changed paths,
not another whole-project audit or a repeat of unrelated test campaigns.
Every implemented change in this plan must also be exercised on live ELTEN
accounts and actual live tables, as close to ordinary use as practicable.
Local-only tests are not sufficient acceptance. Cover all affected supported
games and variants, not just a sample game, while keeping trials targeted to
the changed behavior. Record local, live handler/API and listening results
separately; do not claim an unavailable trial passed. Live failures are to be
fixed and the affected trial repeated before marking that change complete.
Per the maintainer's later instruction, do not test keyboard operation. Use
native control handlers and API paths through MCP for live interaction;
checking form structure or an action result is not a physical-keyboard test.

- Check declarations for every selected game and for excluded games that
  previously exported scores. Check option-dependent direction in Rummy and
  penalty direction in UNO, Domino and Mexican Train.
- Compare normal-result exports with actual public game scores. Cover teams,
  real zero and negative values, custom limits, Audio Ball set totals and the
  distinction between 1000 miles game points and distance.
- Cover each agreed technical-score policy, organizer and automatic results,
  unstarted and inactive unresolved fixtures, repeated confirmation, stale
  previews, a game start or normal result arriving during confirmation and
  uncertain-write reconciliation.
- Verify administrative settlement availability across every registered game,
  not only small-point-enabled games, for eligible non-active fixtures. Include
  absent continuation/checkpoint hooks and disabled scoring without weakening
  lifecycle checks, authorization, result protection or network-failure
  reporting. Missing native history must not imply an unstarted match.
- Exercise the complete multiplayer order editor with three, four and eight
  units, shared places, teams, multiple forfeits and prior eliminations under
  the agreed rules. Check completeness validation, full consequence previews,
  eligible terminal settlement and late native-start/result delivery.
- Check editable administrative small points for selected games, validated
  game-owned suggestions and results not proportional to places. Tournament
  points remain calculated; unsupported games expose no small-point controls.
- Verify one attendee versus three forfeiting participants gives 6, 0, 0, 0,
  while an ordinary non-forfeit shared-second-place result remains 6, 2, 2, 2.
  Cover several prior automatic removals without awarding points among them.
- Check that no manual option, shortcut, retained callback or service call can
  interrupt active play, eliminate a running participant or apply the
  all-participants-zero decision to a running match. A waiting table alone
  must not incorrectly hide the eligible unstarted-fixture actions.
- Verify the separate automatic five-minute path with return before expiry,
  expiry, host changes, supported continuation and automatic terminal
  resolution. It must not depend on opening the organizer's forfeit dialog.
- Verify zero tournament points for automatically removed participants, zero
  small points in higher-is-better games and the configured losing limit in
  penalty games, including custom UNO limits and both Rummy variants. Check
  that continued players keep their actual scores and no partial and technical
  result is double-counted. Cover the approved 11:0 unlimited-Pong fallback.
- Check the zero-award decision for two players, several players and teams:
  zero tournament points for all, no draw points, no small-point contribution,
  correct resolved status and no duplicate start or resolution. Include group
  completion, a knockout bye and a final ending without a tournament winner.
- Exercise multiplayer continuation, terminal scored boundaries, prior
  eliminations and shared places, preserving the ordinary large-point formula
  and applying the explicit zero override only to forfeiting units. Before
  any policy change, retain its historical result fixtures.
- Reproduce the original display failure using verified played results mixed
  with forfeits. Check the new display for complete, partial, absent and
  explicitly zero-contribution data, and for games with support disabled.
- Verify historical receipt loading, account/host changes, cold reads and
  repeated refresh, including unchanged finished classifications and no
  retroactive technical-score additions. Missing dependencies, unavailable
  clients and incomplete trials must not be reported as passing tests.
- For live verification, use the existing native forms, accounts and ordinary
  result/forfeit paths. Cover a supported higher-is-better game, a penalty
  game, multiplayer handling, teams, the zero-award flow and an excluded game.
  Preserve unrelated matches/results; retain exact evidence and clean up only
  owned test resources. Short handler/API trials are not proof of a complete
  physical-keyboard match or listening verification.
- When implementation is authorized, update affected player guidance and
  labels in every supported language and verify native focus/announcements.
- For voice chat, use targeted local checks and live-account trials of
  creation, public/hidden channels, password protection, joining from the
  table, switching from another conference and a late arrival. Verify one
  announcement, no unsolicited dialog or focus change, no duplicate channel
  after concurrent attempts, stale-channel/error handling, preserved audio
  preferences and uninterrupted gameplay/chat. The maintainer subsequently
  excluded a separate listening test: native ELTEN audio delivery is already
  accepted. Focus on the reported join refusals and genuine application paths;
  do not describe muted-microphone or membership checks as listening tests.
- Check the one-second bot default across all games and variants, including
  Duck Racing challenges, and verify that explicitly selected delays remain
  effective. Use targeted timing regressions and affected live trials to
  distinguish decision delay from network latency or view refresh; preserve
  realtime progress, host transfer and normal human input.
- For category changes, verify built-in pools, custom selection, round draws,
  option descriptions and all language editions. Cover old masks and saved
  games, an already drawn removed category and new category identities; do not
  change the category of an existing answer while loading or replaying it.
- For the Mahjong slowdown, run a targeted multi-hand local timing regression
  and later a live ordinary Hong Kong game with bots through at least the
  fourth completed hand. Record timings by hand and confirm continued native
  UI/chat responsiveness. If a shared path changes, cover affected Riichi/MCR
  progression, saved-game continuation and host transfer; protect tournament
  private hands without introducing bots into tournament play. Distinguish
  local simulations, live handler trials and actual listening/human play.

## 12. Implementation and delivery boundary

The maintainer authorized implementation and live tests on 21 October 2026.
Keep implementation status, initial failures and verification evidence in
the local ignored diagnostics directory. Use owned test tables, channels and
accounts; preserve existing real tournaments, matches and results. Do not
change table protection, schema or quotas as an incidental test setup step.
Loading the changed sources for live tests is in scope. A subsequent explicit
instruction also authorizes the signed 2.0.5.4 release, build 255, its
multilingual changelog and pushing the completed changes to GitHub. Verify
the resulting automatic tests. Installing the package or publishing it in
ELTEN's public catalogue is not included in this instruction.
