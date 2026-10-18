# Planned improvements — 18 October 2026

Status: implementation and final verification in progress. This document records
the agreed scope; its checklists alone are not proof of completion. It covers
Countries and Cities, Duck Racing spectators,
tournament controls, verification of server randomness and private hands,
an iterative whole-project audit with fixes and live verification, and
unnecessary input blocking during concurrent chat and game operations.
It also includes auditing and integrating the open GitHub pull requests before
the final whole-project audit, including editorial work on the new game's rules.
After completing that work, rebuild the signed 2.0.5.1 package, update its
changelog and publish the verified sources to GitHub under section 10.
The earlier completed fixes plans remain unchanged.
Recommendations that still need a decision are explicitly marked below.

Latest scope decision, 18 October 2026: stop the broad source audit now,
including the unread remainder of pass 1-f. Preserve completed reviews and
their findings without describing the partial pass as complete or clean.
Finish the agreed features, repair confirmed defects, independently review
the affected paths, run targeted local and live checks, then perform final CI,
sign the package and publish the sources. Earlier exhaustive coverage lists
are evidence indexes, not instructions to repeat completed campaigns or to
resume the broad audit. Section 7.5 governs this reduced completion scope.

The user also ended the long live Battleship trial and accepted the existing
Battleship evidence as sufficient for release. Do not repeat that trial or
hold the release for it. Record the unfinished trial as waived by the user,
not as a completed passing test; retain its measurements and cleanup record.

## Execution policy: no questions during the work

- Do not interrupt implementation, testing or auditing with questions or
  requests for individual decisions. Resolve ordinary implementation details
  from the agreed requirements, current contracts and verified behavior.
  Continue making in-scope corrections and running their affected tests.
- Behavior-preserving internal refactoring and controlled experiments with
  better implementations are approved, subject to section 7.4's evidence and
  acceptance requirements. They need not be limited to single-line patches.
  This does not authorize new game rules, weakened safeguards or a fundamental
  replacement of the application's architecture.
- The user authorizes coordinated subagents for implementation and independent
  verification under section 7.6. Use separate responsibilities to improve
  the evidence and catch mistakes, not merely to split the files for speed.
  This permission does not start implementation while the task is plan editing.
- If a finding would require a substantial change to program behavior, game
  rules, architecture or another major decision not already approved in this
  plan, leave that change unimplemented. Record the evidence, user-visible
  consequences, proposed solution, alternatives and affected tests for one
  final decision list. Recommendations already marked as unconfirmed follow
  the same policy; silence does not authorize them.
- After exhausting safe alternatives, defer only the work that depends on
  missing authority, information or an unavailable external capability.
  Continue independent implementation, review and testing. Do not bypass
  protections, guess a consequential rule or disguise a blocked test as a pass.
- Keep concise progress updates, without turning them into questions. At the
  end distinguish completed and verified changes from deferred decisions and
  incomplete coverage. If only decision-dependent work remains, report that
  state rather than waiting indefinitely or claiming everything was fixed.
- This policy concerns questions to the maintainer during development. It does
  not remove the game's required confirmation dialogs or their test coverage.

## 1. Countries and Cities: feedback, review and round pacing

- Play a short sound once when a participant's submitted answers are accepted.
  Do not reveal their contents before the existing reveal stage.
- Group the review by category, then by answer/player, rather than showing
  every category for one player before moving to the next. Preserve the
  existing grouping and scoring of identical answers.
- When the judge focuses an answer, append the short hint "Enter confirms
  the assessment" (Polish: "Enter zatwierdza ocenę"). Arrow keys select an
  assessment; Enter confirms it. Do not repeat the hint for every arrow-key
  change, silent refresh or network update.
- A successful confirmation gives the judge a short "Assessed" feedback
  (Polish: "Oceniono"). Report success only after the assessment is actually
  accepted, not merely when Enter is pressed. Do not announce success for a
  rejected/stale action, duplicate Enter or an uncertain write. Keep this
  local interaction feedback out of other players' speech and game history;
  preserve existing meaningful assessment history and scoring.
- Clarify the drawn letter in answer-field labels with a short familiar word
  in the interface language, particularly for easily confused letters such as
  M and N. Do not supply an answer to the selected category through the example.
  Prepare appropriate wording for each supported interface language.
- Play a distinct, one-time sound when answering time expires, alongside the
  existing spoken message. Do not replay it after refresh or reconnection.
- Play a separate one-time warning when 20 seconds remain in Countries and
  Cities. Keep the answering deadline authoritative; do not replay an elapsed
  warning after refresh/rejoin or delay the round to finish the recording.
  Check that this cue and the time-expired cue are both present and distinct.
- Default new games to 50 points. Preserve explicitly chosen settings.
- Add two seconds to the pause after review and the score summary, before the
  next round starts. Use a fixed deadline, not synthesizer completion. The next
  round's answering time must not run during this pause.
- Record all players' final cumulative scores in history at the end of a game.

Primary implementation area: `games/categories.rb` and its existing shared
surfaces, presentation and sound hooks. Do not introduce a separate game loop.

## 2. Ordinary games: removing departed players in Countries and Cities only

Confirmed scope for ordinary games: automatic removal is being planned only
for Countries and Cities. Do not extend this ordinary-game policy to Scrabble,
Taboo, Krowa or every game without bots. Tournament matches use the separate
return-time and forfeit policy in section 4, not immediate roster removal.

### Departure evidence

- Act on confirmed loss of native LiveSessions membership, including a
  server-confirmed expiry, not a temporary transport error, missing packet,
  quiet player, covered window or unsuccessful membership read.
- The current disconnected label represents a game participant absent from
  table membership. Revalidate that absence before committing removal; a stale
  screen label alone is not authority.
- Use the existing host/executor and membership notifications. Do not add
  polling, an independent disconnect timer or a second executor.
- If the player returns before removal is committed, discard the stale
  removal. After committed removal, returning does not automatically restore
  their place in the current game.

### Planned ordinary-game behavior

- Remove a departed contestant from the active roster and the sets of required
  submissions/reveals. Do not wait indefinitely for their answers.
- Discard their answers from an unfinished round. Re-evaluate affected
  identical-answer groups so remaining players are not penalized by an answer
  that is no longer participating. Preserve fully completed rounds and their
  historical scores.
- If the current judge departs before the round is scored, cancel that
  unfinished round. Select the next available judge under the selected mode,
  then start a fresh round with a new draw and the full answering time. In
  permanent-host-judge mode, the new host becomes judge. Do not cancel an
  already scored round.
- A host departure alone does not cancel a round if the judge remains.
- Adjust later judge rotation and the final round cycle to the remaining
  players, without rewriting completed rounds.
- With fewer than two available participants, end the ordinary game as
  interrupted, not as an automatic victory for the remaining player.
- A removed participant may return as an observer and play in a later game.

Implementation must preserve the immutable event log. Express removal and
round cancellation through the existing validated event/replay path, rather
than mutating cached state or deleting historical actions.

## 3. Duck Racing: observing challenges

The same observation policy applies to table spectators and race players who
are not taking part in the current challenge.

### Shared presentation rules

- Spectators never hear the countdown recording and never have to confirm
  readiness. Keep countdowns and input instructions for actual participants.
- Announce the challenge and its permitted information once. Reuse existing
  messages, sounds and results rather than adding a second presentation path.
- Never disclose private typed answers before the challenge resolves.
- Joining, refreshing or returning to the window must not replay a backlog of
  old countdowns, shots or selections.
- Reuse the current challenge clients, presentation and transient channels.
  Do not persist each key press just to support observation.

### Observation by challenge

| Challenge | Information for nonparticipants |
| --- | --- |
| Rock, paper, scissors | Who has chosen; choices remain hidden until the result. |
| Dice duel | Current player, roll sound/value and result. |
| Twenty-one | Initial cards on that player's turn, draws, totals, standing or exceeding the limit, then the next turn and result. |
| Risky dice | Current player, rolls, running total, banking or losing the turn's points, and result. |
| Guess the number | Final target, final guesses used for comparison and result only; no live attempts or hints. |
| Copy the number | Final numbers and result only; no initial prompt, typing or countdown. |
| Mental arithmetic | The calculation, then the final correct answer and result; no countdown or private attempts. |
| Race question | The question, then the answer and result; no private attempts. |
| Numbered balls | Available balls, current player and selected values; running totals on request rather than repeated after every action. |
| Count ducks | The duck sounds and final answer/result, without the countdown recording. |
| Rhythm | Final scores and result only. |
| Order the sounds | Final result only; no notes, swaps or private arrangement. |
| Simon | Final completed-sequence scores and result only; no melodies or inputs. |
| Sound pairs | Current player, transient chosen digit and sound, correct/incorrect feedback, then next turn or result. Do not retain discoveries in history. |
| Hit the duck | Final scores and result only; no target sounds, shots or individual hit feedback. |
| Quiz | Question and choices, submission progress, then revealed answers/result. Apply to field/card questions too. |
| Audio Ball | Reuse existing realtime observation, checking both kinds of nonparticipant; no player controls. |
| Axel Pong | Reuse existing realtime observation and perspective selection, checking both kinds of nonparticipant; no racket controls. |

Primary areas: the existing files under `lib/duck_racing/` and the game's
presentation hooks. Check existing behavior first; do not duplicate working
Pong/Audio Ball observation or existing final-result announcements.

## 4. Tournament matches: consistent action availability

### Confirmed UI change

Hide actions that are not available at the current tournament table. The
context menu, visible controls and context help must agree about availability
and advertised shortcuts. This covers the waiting room, active match and
finished-match screen, including the selected participant's menu.

Derive this from a shared availability decision using the tournament binding,
current role, match phase and existing game capabilities. Do not maintain
parallel lists of game IDs or copy conditions into individual menus.

- In particular, do not offer replacement when private hands make it
  unavailable. Hiding replacement must not also hide a valid
  host transfer: they are distinct actions even though the current menu groups
  them under control management.
- Preserve execution-time checks and revalidation. Hiding an option is not
  authorization or an anti-cheat measure. A stale selection or direct shortcut
  must not execute a now-forbidden action; explain the refusal briefly.
- Determine presentation availability from already available state; opening a
  context menu must not introduce a network request for every entry.
- Refresh availability quietly when the host, role, phase or roster changes,
  preserving selection where possible.
- Keep ordinary tables' behavior unchanged unless separately agreed.

Primary areas: `lib/participant_menu.rb`, its callers in `__app.rb` and active
game surfaces, `lib/game_screen.rb`, `lib/context_help.rb`, and the existing
game capability/permission hooks in `games/base.rb`.

### Confirmed restriction: no saved tournament matches

Apply this uniformly to all tournament games, not only games with private
hands:

- Hide "Save the game and close the table" and its Ctrl+S help entry in
  tournament matches. Direct shortcut/action execution must also reject saving.
- Do not restore a tournament match from a saved-game file or accept such a
  restored session as a valid tournament result. Preserve these checks below
  the UI; hiding the menu item alone is insufficient.
- A returning player may reconnect to the same still-available server session
  while still eligible to continue under the departure policy below. This is
  not file-based restoration and remains supported.
- Ordinary games retain their existing save/restore behavior. Saving table
  history as text is a separate function and is not prohibited by this rule.
- Do not delete existing files as part of implementing this restriction.

Reason: the current archive checksums and replay validation do not independently
prove that a supplied file describes the original match. A checksum recalculated
by the file's owner is not protection against deliberate modification. This
restriction closes the saved-archive route; it is not a claim of complete
protection against modified clients.

### Confirmed: five-minute return allowance and automatic 1v1 forfeit

For a started individual 1v1 tournament match, a player confirmed as
disconnected has five minutes of return time. Once that allowance is exhausted,
remove the player from active participation and award the opponent a walkover,
without waiting for the organizer and regardless of the current score. Keep
the original fixture roster and history as evidence of who forfeited; removal
does not mean deleting the participant from the result record.

Retain the previously proposed cumulative allowance, changing its value from
three to five minutes: count confirmed disconnected time across the whole
match. Rejoining stops the clock but does not replenish the allowance. For
example, after four minutes absent, the next disconnection leaves one minute,
not another five. A player continuously disconnected for five minutes therefore
forfeits; repeatedly leaving and returning cannot restart the allowance.

- Start counting only after confirmed native membership loss, not a quiet
  client, covered window, failed read or Communications interruption. This is
  the authoritative condition behind the disconnected label, not merely text
  observed in one client's list.
- Pause the match while waiting, including turn/answer deadlines. A timely
  return resumes the same state, cards and scores; do not create a new game.
- Preserve the allowance and recorded absence intervals across host changes
  and client reconnects. Store match/account-scoped observations in the shared
  history, with a common time basis; do not reset the allowance at every new
  host or rely only on a timer kept in one process.
- Before awarding the walkover, revalidate the current fixture, membership,
  absence boundary and result status. A stale timer must not remove a player
  who returned in time, overwrite a completed result or award the result twice.
- Once the walkover is committed, returning cannot reopen this match or reclaim
  its playing seat. Do not substitute a bot or another player.
- Server-wide failure, unavailable/contradictory membership evidence, or both
  players being absent must not automatically manufacture a winner. Preserve
  the unresolved state for recovery or organizer review.
- This is a started-match rule. Do not convert an unanswered invitation or an
  unstarted waiting room into an automatic sporting defeat.

The existing manual-forfeit path is restricted to the organizer. Define and
validate the automatic timeout outcome separately, with explicit authorization
for the current match coordinator; do not bypass the organizer check in the
manual path.

#### Accepted trust boundary, 18 October 2026

The user explicitly accepted relying on the current host client's assertion
of disconnection after inspection showed that the available API does not
provide retained, independently verifiable absence intervals. The ordinary
client must base these assertions on native membership loss, not missing game
packets, a covered window or its own failed connection. Retain the assertions
and accumulated allowance in the shared match history for recovery and host
transfer, and revalidate current membership before applying the outcome.

Authentication identifies the client that recorded an observation; it does not
prove that the observation was truthful. Server timestamps can establish when
a record was accepted, not that the player was absent. This mechanism handles
disconnects between normal clients but does not protect against a modified
host fabricating absence. Do not describe these records as server-certified
membership evidence or as an anti-cheat guarantee. This explicit decision
replaces the earlier requirement for independently certified absence; the
other return, pause, race, idempotency and failure safeguards above remain.
Keep this technical trust-boundary explanation out of README and all
player-facing documentation, as requested by the user. Player help describes
only the applicable return allowance and match outcome.

### Confirmed: interrupted individual matches with three or more players

Apply the same cumulative five-minute return allowance, confirmed membership
evidence, pause while awaiting return, host-transfer protection and commit-time
revalidation as above. After one player's allowance expires, use one of these
two outcomes:

1. **The game can continue without that player.** Eliminate the disconnected
   player from active play and let the remaining players finish the same match.
   Their play determines their places; the eliminated player takes last place.
   Continuing must be supported by the game's rules and current phase, without
   adding a bot, exposing private hands or silently changing the game variant.
2. **The game cannot continue without that player.** End the match
   administratively. Place the disconnected player last, regardless of their
   score. Rank everyone else by their cumulative game scores at the latest
   fully completed, scored round or deal. Do not include an unfinished round
   or compare players at different scoring boundaries.

- Use the game's score direction: higher scores are not universally better.
  Equal scores share a place under the existing tournament ranking rules.
  Keep game scores distinct from tournament points; the existing tournament
  points formula applies to the resulting places.
- Last place is an explicit outcome, not a replacement score of zero. Zero
  could otherwise put a forfeiting player ahead of someone with negative
  points. Preserve the original fixture roster, actual scores and history.
- Determine whether a scored round exists from accepted game progression,
  not from whether any score is nonzero. For example, a completed 3-5-8 deal
  can legitimately leave every player on zero. Such a result is usable and
  ties the remaining players; it does not make the match unplayed.
- If continuation is impossible and no round or deal has been fully scored,
  give the remaining players a shared first place by walkover and put the
  disconnected player last. Do not reset the fixture to unplayed, which would
  allow a player to abandon an unfavorable opening and force another attempt.
- Distinguish a genuinely absent scoring checkpoint from a failed read or an
  unsupported scoring contract. Missing or uncertain data is not zero and
  must not authorize an automatic result.
- Example: Anna has 80 points, Bartek 30 and Celina 120 at the last completed
  scoring boundary. If Celina exhausts her allowance and play cannot continue,
  Anna is first, Bartek second and Celina last: 4, 2 and 0 tournament points.
  With no completed scoring boundary, Anna and Bartek share first place by
  walkover: 3, 3 and 0 tournament points.

Implement this through the shared tournament outcome path, with game-provided
continuation eligibility and scored-checkpoint data. Do not add a separate
disconnect executor or per-menu game exceptions. Preserve the requirement for
a finished replay when accepting a normal played result; an administrative
interruption is a separately validated outcome, not a fabricated game finish.
The organizer must not guess the order in which the remaining players would
have finished. This policy resolves an interrupted match; it does not claim to
predict the eventual sporting result or prevent every form of collusion.

Team-wide allowances and automatic team forfeits still require an explicit
policy decision. Do not infer a losing team or the ordering of several timed-out
players from this single-player rule. Simultaneous or ambiguous departures
without an agreed outcome remain unresolved for recovery or organizer review.

### Confirmed: organizer's manual forfeit through Ctrl+F

Replace the separate unstarted-match Ctrl+F and started-match Ctrl+Shift+F
actions with one context-menu action, "Przyznaj walkower" ("Award forfeit"),
advertising Ctrl+F. It is available to the organizer for an unresolved match;
the current match state determines its consequences. Remove the redundant
Ctrl+Shift+F entry and update context help with the same availability rules.

The interaction is:

1. Select **who loses by forfeit**, not the winner. The Polish list label is
   "Kto przegrywa walkowerem?". For a team fixture, select the whole team as one
   competitive unit, not an individual teammate. Do not add a manual editor
   for scores or an organizer-defined ordering of all participants.
2. Show the consequences before writing anything:

   - In 1v1, the opponent wins by forfeit.
   - In a started multiplayer game that can continue, the selected participant
     is eliminated and takes last place; the others continue. Do not mark the
     entire fixture complete or invent the remaining places at this point.
   - If the started game cannot continue, rank the remaining participants by
     cumulative completed-round scores using the settlement rules above.
   - If continuation is impossible and no round has been scored, give the
     remaining participants shared first place by walkover and the selected
     participant last place.
   - For a match that has not started, also give the remaining participants a
     shared victory by forfeit. This requires the organizer's explicit
     decision; an unanswered invitation still causes no automatic defeat.

3. Ask for one explicit confirmation. For a terminal result, list every place
   and its tournament points, naming who loses by forfeit and stating that the
   match will end. For continuation, name the eliminated participant and say
   that the others will keep playing. Cancel or Escape must write nothing.

For example, the terminal preview may say that Celina loses by forfeit, the
match ends, and Anna receives 4 tournament points, Bartek 2 and Celina 0.
The continuation preview instead says that Celina is eliminated into last
place while Anna and Bartek continue; no final standings are claimed yet.

- This is an authorized manual decision, separate from the automatic
  five-minute absence rule. Do not require the organizer to wait for that
  timer when deliberately resolving a resignation or no-show.
- Revalidate organizer authority, fixture identity, current progression and
  result status before committing. If relevant state changes while the dialog
  is open, show the updated consequences and require confirmation again. If
  the match has already been resolved, refuse rather than overwrite it.
- A failed score read is not a zero score or proof that no round was played.
  Block settlement until the required state is known. Reconcile an uncertain
  write instead of publishing the decision again under a new identity.
- Record who forfeited, which organizer made the manual decision, and how the
  remaining places were established. Show this in match history and result
  details; retain the original participants and actual game scores.
- Reuse the shared settlement/continuation policy above. Manual authorization
  and automatic-timeout evidence remain distinct validation paths; selecting
  a whole team manually does not authorize automatic team forfeits when one
  member disconnects. The automatic team policy remains undecided.

Primary areas: `lib/tournaments/server_schedule_overview.rb`,
`lib/tournaments/server_forfeit_screen.rb`, `lib/tournaments/ordinary_match_forfeit.rb`
and their existing program entry points, result presentation and context help.

### Recommended common tournament policy — to confirm before broadening restrictions

Use the same competitive rules for all tournament matches:

- Keep the assigned players and teams fixed. No additional competing players,
  bot replacements or swapping players between teams. Unassigned visitors are
  observers, as in the existing tournament entry path.
- Keep match variants/settings bound to the tournament configuration rather
  than letting the table host change them during the match.
- Allow the same account to reconnect to its assigned place while eligible to
  continue. A temporary departure is not an immediate defeat or permission to
  replace that account; the confirmed individual-match timeout rules above
  limit waiting.
- Keep host transfer distinct from changing the competitive roster. Allow it
  when the existing private-phase guards permit it.
- Preserve chat, rules, history, permitted spectator functions and personal
  accessibility/audio settings.

The uniform save restriction above is confirmed and supersedes the earlier
recommendation to preserve saves in some tournament games. For other actions,
continue to use shared capability and permission checks rather than ad-hoc
lists of game exceptions. The broader roster policy in this subsection remains
a recommendation pending confirmation.

The ordinary Countries and Cities removal in section 2 must not bypass the
tournament return allowance. In individual tournament matches, use the same
five-minute allowance as in other games: a walkover in 1v1, or the confirmed
multiplayer continuation/settlement policy above. Its ability to continue with
fewer players must still handle judge departure and unfinished rounds. Do not
extend this to automatic team forfeits before their policy is agreed.

## 5. Verification and completion requirements

When implementation is requested, test every affected behavior locally and on
live accounts, including both normal and tournament tables where relevant.
Do not rerun unrelated complete suites merely because a plan was updated.

### 5.1. Real matches are the primary acceptance evidence

The maintainer explicitly requires tests as close to ordinary play as possible,
not just successful API operations or an advancing model. For every change,
use actual ELTEN accounts and normal Power Games windows, from creating or
joining a table through playing and seeing the result. Pure model tests,
isolated transport probes and direct calls to production methods supplement
these matches; none of them alone counts as a passed live-play scenario.

- Record the exact source revision or source hashes, ELTEN version, loaded
  application/build, accounts, roles and table/game/match IDs. Verify that every
  participating copy has the intended sources, not an older hotloaded runtime.
- Use separate profiles/accounts: two, three or four people as required by the
  game's real player limits, plus spectators where needed. Rotate the creator,
  host, first seat, returning player and observer. Test individual and supported
  team variants; do not simulate several human accounts with one host's model.
- Navigate ordinary menus and invoke actual controls and their handlers. Include
  keyboard-driven entry for changed shortcuts, lists and editable fields. If a
  trial uses control handlers rather than physical key presses, identify that
  explicitly; it does not prove physical keyboard or screen-reader behavior.
- Keep the normal executor, network validation, background presentation, timers,
  server draws and account-owned private reads active. Do not finish a match by
  assigning its score/state, injecting a winner or bypassing normal move writes.
  Use supported short-game settings when useful, recording the chosen options.
- For each affected game and supported ordinary/tournament mode, include a
  completed match with ordinary legal moves, final history/result and, for a
  tournament, the recorded standings. A few moves or one completed deal must be
  labelled as such, not presented as a completed match. If a full match cannot
  be completed, record the missing coverage rather than silently reducing it.
- Combine scenarios within a match where realistic, but give each assertion its
  own outcome. Repeat critical timing/recovery cases at least three times after
  the last relevant fix, including a clean final run without intrusive probes.
  Recheck all directly affected scenarios after a fix; an earlier pass against
  different code is not evidence for the final version.
- Include play while Messages, a menu or a confirmation dialog covers the game,
  returning to the table, and changing focus between accounts. Confirm actual
  speech delivery, sounds, focus, editable text, permitted shortcuts and usable
  controls. A matching replay or a sound function call alone proves neither
  audible output nor a responsive interface.
- Preserve the user's audio preferences. Inspect output through scoped
  diagnostic capture and, where possible, listening. If the environment prevents
  physical input or listening, report that limit rather than marking it tested.
- Use only owned diagnostic tables/matches and controlled accounts for malformed
  commands, failures and security probes. Do not touch other people's games,
  publish trial results to public rankings, or weaken production protections.
  Clean up only identified test resources and remove temporary instrumentation.

Four copies on one computer test real accounts and server behavior, but not
four independent networks or machines. Add a different-computer/connection run
where available; otherwise identify that remaining limit. No test campaign can
guarantee the absence of every bug. Completion means passing the documented
matrix on the final code, with failures and untested cases disclosed, not a
claim of complete anti-cheat or mathematically certain reliability.

### 5.2. Required coverage of every planned change

- Countries and Cities: submissions, timeout, category-first review, identical
  answers, score history, pause and next-round deadline. Departure while
  answering, revealing and reviewing; judge and non-judge host departure;
  return before/after removal; simultaneous departures; insufficient players;
  stale notifications and failed membership reads. Check judge rotation and
  final-round completion after a removal.
- Duck Racing: each listed challenge, both spectator roles, participant
  countdowns still working, no spectator countdowns or readiness prompts,
  no duplicate feedback, no private-data leaks, join/rejoin mid-challenge,
  background presentation and host change. Confirm actual delivered speech
  and sounds, not merely model progression.
- Tournament UI: role/phase/capability matrix covering host, player and
  observer; waiting, active and finished matches; private and ordinary state;
  save, replacement and host-transfer guards. Check menu entries, shortcuts,
  context help and stale-action execution together. Verify that tournament
  saving, file-based restoration and acceptance of restored results are blocked
  for every game, while reconnecting to the original session still works.
  Check ordinary saves/restores and history-text export remain available where
  supported.
- Tournament departure: five uninterrupted minutes absent; several absences
  totaling five minutes; return before the limit; the return/expiry race;
  host departure and transfer without resetting the allowance; paused gameplay
  deadlines; 1v1 walkovers independent of the current score; duplicate callbacks
  and uncertain result writes; already finished matches; both players absent and
  server/read failures; return after a committed walkover. Verify no automatic
  forfeits in unstarted rooms or in unapproved team/multiple-departure cases,
  and no immediate ordinary-game removal in a tournament Countries and Cities
  match.
- Individual multiplayer departure: continue a supported game with the
  remaining players and retain the eliminated player in last place; settle a
  game that cannot continue from cumulative completed-round scores only.
  Cover an unfinished deal, a forfeiting leader, negative scores, lower-is-better
  scoring, tied survivors, a genuinely scored all-zero 3-5-8 result, and shared
  first place by walkover when no round was scored. Verify the existing
  tournament points formula, original roster/history, and distinction between
  an absent checkpoint and a failed read. Repeat return/expiry, host-change and
  duplicate-result checks for both continuation and administrative settlement;
  do not invent team or multiple-departure outcomes.
- Manual Ctrl+F: one advertised action for started and unstarted matches;
  organizer-only access; losing-player and whole-team selection; preview of
  continuation versus final places/points; Cancel/Escape without writes.
  Check shared victory in an unstarted match, completed-round settlement and
  no-completed-round fallback, with no manual score/rank editor. Exercise state
  changes while the dialog is open, normal completion racing confirmation,
  failed reads and uncertain writes; verify renewed confirmation where needed,
  no result overwrite, and decision history/result details. Continuing a match
  must not prematurely publish a terminal result or bypass automatic-timeout
  safeguards for other participants.
- Update relevant player documentation and translations in all supported
  languages when implementing the features. Keep rulebook editorial rules
  and creator-supplied text protections.

### 5.3. Live acceptance scenarios for sections 1-4

- **Countries and Cities feedback and review:** create a default table and a
  table with an explicitly different target, checking 50 points only becomes
  the new default. Play with at least three accounts and multiple categories.
  Submit from different seats, include identical answers, near-identical
  spellings and a timed-out player. Check submission/timeout sounds once, no
  premature disclosure, category-first review, unchanged scoring and readable
  letter labels. Check the 20-seconds-remaining and time-expired cues, including
  a background window, fresh/cold replay and reconnection with less than
  20 seconds left; neither cue may repeat or be reconstructed belatedly.
  Focus each review answer, select by arrows and confirm by Enter: the short
  hint must explain the distinction, and accepted confirmation must produce
  one local acknowledgement. Repeat Enter and test stale/rejected/uncertain
  confirmations and a silent refresh, without false success or repeated hints.
  Repeat relevant UI checks in every supported language.
- **Countries and Cities pacing and finish:** complete review normally, let
  deadlines expire, cover the window during the pause and return. Measure the
  additional two seconds separately from speech; the next answer deadline
  starts after the pause. Finish a match and inspect each account's final history
  for every player's total, with no duplicated results after refresh/rejoin.
- **Countries and Cities departures:** in separate live phases, remove a
  contestant while answering, after submission, during reveal and during
  review. Check the pending participant sets, discarded unfinished answers and
  recalculated duplicate groups. Repeat with the current judge and with a host
  who is not the judge; verify round cancellation only where required, the new
  judge, a fresh full answering period and preserved completed scores. Test
  return before removal, return as observer afterwards, the final round cycle,
  and fewer than two players. Contrast an actual native departure/expiry with
  a failed membership read, transport interruption and a merely covered window.
- **All 18 Duck Racing challenges:** play each challenge listed in section 3
  with real competing accounts, a nonparticipating racer and a table spectator
  where the participant count permits. Use normal race/card encounters for
  end-to-end coverage; an existing lab may target rare challenges but is not a
  substitute for their normal entry path. Check both permitted information and
  information that must remain absent. Observers never receive the countdown
  recording, input controls or readiness requirement. End-only challenges stay
  quiet until their permitted final results; Simon reveals no melodies/inputs.
- **Duck Racing observation lifecycle:** exercise opening, readiness, individual
  turns, simultaneous input, timeouts, results, feather settlement and return to
  the race. Join/rejoin during a challenge and change host where supported.
  Verify transient sound-pair digits do not enter history, private typed answers
  do not leak, and refresh/background return causes no replayed backlog. Check
  Audio Ball and Pong perspectives and sounds, not just model positions. Leave
  a normal participant unable to act and verify spectators cannot satisfy that
  participant's readiness or actions.
- **Tournament entry and controls:** create real diagnostic tournaments through
  the normal UI, join them, start fixtures through ordinary invitations and
  Ctrl+J, then play. Test two-person, three-person and four-person fixtures and
  supported teams; include an unassigned visitor becoming an observer. For host,
  participant and observer, inspect menus, help and direct shortcuts before,
  during and after a match. Unavailable actions must be absent and stale/direct
  execution must still fail safely. A permitted host transfer remains distinct
  from forbidden replacement.
- **Tournament save restriction:** on private-hand and other tournament games,
  try the menu, Ctrl+S, direct action and a controlled pre-existing tournament
  archive. Neither restoration nor its submitted result may be accepted. In
  contrast, reconnect to the same live session successfully. Verify ordinary
  save/resume and text-history export still work; do not delete users' archives.
- **Five-minute allowance:** run actual elapsed-time trials for one continuous
  five-minute absence and cumulative absences such as four minutes plus one.
  Include a return just before expiry and shortly afterwards, host transfer
  during absence, normal completion racing expiry, a covered game, and paused
  answer/turn deadlines. Check one committed outcome on every account and in
  standings. Fast local clock tests supplement, not replace, these live waits.
  Simultaneous absences, uncertain membership and server errors must not create
  a winner. Do not force genuine server-wide outages to obtain this evidence.
- **Multiplayer resolution:** use a real game that can continue and one that
  requires the full roster, including a scored and an unscored interruption.
  Reach game scores through legal play, compare the last complete scoring
  boundary, and exclude unfinished rounds. Exercise tied, zero and negative
  scores and a forfeiting leader. Complete the remaining play where supported;
  check places, tournament points and preserved fixture participants. Exact
  rare score patterns may additionally use local fixtures, reported separately
  from the scores actually reached in live matches.
- **Manual Ctrl+F:** act as organizer and as a non-organizer, on unstarted,
  active and completed matches. Choose a losing player or whole team, inspect
  the proposed consequence, cancel once and confirm once. Test continuation,
  terminal score-based settlement and shared victory without a scored round.
  Let another account progress or finish the match while the dialog is open;
  check fresh confirmation or refusal, never an overwrite. Check one decision
  record, who made it, its final presentation, and agreement across accounts.

## 6. Server randomness and private hands: extended verification campaign

This is an additional test scope for the newly introduced randomness/private
state paths, not an instruction to migrate more games or change their rules.
Use `docs/PRIVATE_STATE.md`, the current registrations and actual game adapters
as the starting inventory. Reconcile documentation against running code first.

### 6.1. Per-game and per-mode matrix

Maintain one row per game, mode, meaningful variant and scenario, with expected
behavior, local evidence, live evidence and a final status. Shared code passing
once does not certify every adapter. Exercise every registered random command,
not only the initial deal or first dice roll.

Current source inventory to verify individually:

| Path | Games and operations that need their own coverage |
| --- | --- |
| Dice and public draws | Cat, head, tail; Farkle; Ludo; Monopoly; Yahtzee; Duck Racing race actions, Dice Duel and Risky Dice rolls, including automatic expiry. |
| Public shuffled deals in ordinary games | Mille Bornes, Spades, Thousand, 3-5-8, 99, Poker, War, Rummy, Makao, Domino, Mexican Train, Scrabble, Biblios, UNO and Taboo; include exchanges, recycling and fresh deals where applicable. |
| Other registered random choices | Audio Ball's initial server, Quiz category/question draws and Countries and Cities round letters; include Scrabble exchanges and every payload recipe registered by the games above. |
| Server-private tournament state | Mille Bornes, Spades, Thousand, 3-5-8, 99, Poker, War, Rummy, Makao, Domino, Mexican Train, Scrabble, Biblios and UNO hands; Taboo selectively shared phrases. |

Normal tables currently use public server randomness; it does not hide the
deal from a modified client. Supported private tournament tables use
account-owned draws instead. Verify the live protocol and binding, not only a
local option: private mode must not be omitted, downgraded or replaced by public
randomness after an error. Test supported human/bot and team combinations in
ordinary games; private tournament starts must refuse bots or replacement.
Games without bots or a given variant should reject it, not be marked as tested
with an invented substitute. An offline simulator's explicit local-random mode
must never leak into a real endpoint, including manual/local event dispatch.

Duck Racing currently has public server randomness, not server-private card
hands: unlimited independent card draws must not be replaced by a finite deck
just to obtain a passing privacy test. Record that limitation explicitly.
Krowa words, Battleship fleets and Scientific War selections keep their existing
private protocols; use targeted regressions for affected shared hooks, without
claiming that these games were migrated to native private card pools. Quiz's
distributed question files are not secret merely because the draw is server-side.

### 6.2. Public randomness, atomic writes and replay

- On every client, compare the accepted native receipt, displayed dice/cards,
  game consequences, turn and history. Check authenticated server origin and
  exact game recipe: count, sides, kept dice, sorting, seat/dealer selection,
  round/session identity and payload format. A server-generated value from the
  wrong recipe is still invalid for that move.
- Exercise repeated rolls, holding/rerolling selected dice, extra turns and
  chained consequences, not only initial randomness. Verify that kept dice do
  not change and limits/ranges follow the selected rules. The client must not
  replace an unfavorable roll, supply its own live seed or predict a future
  roll from a previously published seed where a fresh draw is required.
- Check boundary values and deterministic mapping with local native-receipt
  fixtures: minimum/maximum values, zero-based indexes, selected seats and
  integer/payload seeds. Use a local distribution sanity check to catch constant
  results, unreachable outcomes or obvious mapping bias. Ordinary live samples
  complement that check; they neither prove statistical fairness nor justify
  generating high-volume requests against the server.
- In owned test sessions, attempt forged random metadata, altered results,
  wrong recipes, old receipts from another round/table, unauthorized actors and
  repeated commands. Observe what the real API rejects and what every game
  replay rejects; distinguish server enforcement from honest-client validation.
  Malformed traffic must not advance the legitimate match or alter its score.
- Compare card/tile multisets and unique physical IDs after dealing, drawing,
  exchanging and recycling. Identical card faces are valid where the deck
  contains several copies; duplicated physical cards or missing stock are not.
  Confirm legal repeats for with-replacement draws instead of banning them.
- Verify the combined native randomness/pool operation and game command use
  the intended single write where supported. Document required extra operations
  such as pool setup or Mille Bornes safety ordering; do not disguise them as
  one request or remove them solely to reduce counts.
- Lose a response before submission and after server acceptance, then retry or
  reconnect. Reuse the operation identity, recover the accepted draw and apply
  it once. Do not reroll, consume a second card, publish half a move or announce
  the same result twice. Test repeated Enter and two competing actions too.
- Rebuild from a fresh replay on another account after several rounds, with a
  cold cache and delayed/duplicate/out-of-order delivery. Accepted state and
  subsequent legal actions must agree. Replay never obtains new randomness.
- Restore ordinary archives made before and after the randomness change; keep
  historical RNG semantics and continue through the next new server-backed
  move. Do not remove provenance checks on live events to make archives pass.

### 6.3. Private-hand confidentiality and ownership

For each supported game, test from the drawing player, an opponent, a teammate
where applicable, the host, a spectator host and an ordinary spectator. Inspect
both the normal UI and the data actually obtainable by each account.

- After the initial deal and later draws, the owner can read and play their
  cards. Other accounts see only permitted counts/opaque identifiers, not the
  values or a seed that reconstructs hidden stock. Check native stack records,
  public metadata, shared messages, snapshots, history and diagnostics for
  unintended disclosure. Private data from one account's cache must not appear
  in another account's replay or another table using the same process.
- Use actual account-specific SDK reads for a known foreign draw/pool ID.
  Confirm that the response does not disclose hidden values; a hidden UI row
  alone is insufficient. Host status must not grant access to other hands.
  Record actual server responses rather than assuming a particular error code.
- Attempt wrong-owner reveals, nonexistent positions, duplicate use of a card,
  forged native-pool proof, a receipt from another match and a stale hand
  selection. Reject the action without creating cards, changing the turn or
  corrupting the legitimate owner's hand. Test directly bypassing UI guards
  only inside controlled diagnostic sessions.
- Verify pool configuration on every client before dealing: size, range,
  privacy and identity. A missing or contradictory configuration must stop the
  private start, not quietly use public draws or fabricated cards.
- Reconnect the same account with its private cache absent and recover exactly
  the same hand, counts and pending operation. Reading the hand again must not
  draw again. An opponent or replacement account must not inherit that receipt.
- Check both allowed public exposure and retained secrecy: played/transferred
  cards may become technically public, but unrelated held cards remain private.
  The ordinary UI must still follow the game's disclosure rules. For UNO 0/7,
  the entire transferred hand is technically public; do not label that case
  fully secret. Thousand/3-5-8 exchanges have the same explicit boundary.
- Cover rejected actions after an irreversible native reveal, such as a late
  UNO interception. The revealed value may already be known, but rejected play
  must not remove the card or change the turn. A later legal play reuses the
  existing evidence once instead of issuing an ineffective repeated reveal.
- For trick games, test both valid and deliberately inconsistent hidden-hand
  claims followed by authenticated disclosure. The completed-round audit must
  reject a proven rule violation before scoring, while a cold replay with an
  unavailable historical private value must not invent a violation. Distinguish
  delayed auditing from immediate server-side validation, which is not provided.
- Inspect whether future stock, excess draws or hidden-hand predicates can be
  abused through permitted SDK operations. Classify each finding honestly:
  server-enforced restriction, client validation, intentional disclosure or
  unresolved API limit. Do not claim that private hands prevent collusion,
  lying about an undisclosed predicate or disruption by an authorized owner.

### 6.4. Game-specific dealing and disclosure paths

The shared scenarios above apply to every adapter. Add these targeted matches
and phases instead of accepting one representative card game as coverage:

| Game | Additional paths to exercise in ordinary and private modes where supported |
| --- | --- |
| Mille Bornes | Initial hands, normal draw/play/discard, safety reaction against an in-flight draw, uncertain draw intent, recycling, fresh round, teams and final scoring. |
| Spades | Bidding, following suit, supported individual/team variants, complete-hand disclosure/audit and one round score only; host change during bidding and play. |
| Thousand | Supported player/team counts, bidding, kitty, passing cards, contract, complete deal and scoring; disclose only transferred cards before the normal reveal boundary. |
| 3-5-8 | Contract choice, kitty, both exchange directions and pending return, normal/misere targets, full deal, next deal and final match; preserve ordered-card evidence. |
| 99 | Play plus replacement draw, special values/direction/penalties, elimination, timeout, recycling and next round; no half-completed play/draw. |
| Poker | Each supported deck/deal variant, bets/fold/all-in and side pots, card exchange, community/burn cards, showdown, uncontested finish, stock exhaustion and new deal. Folded hands and burns stay private except explicitly required recycling disclosures. |
| War | Ordered next-card play, a tied battle, face-down battle cards, collected pile order, exhaustion and winner; preserve the documented technical disclosure of battle cards without changing face-down UI. |
| Rummy | Draw from stock/discard, staged meld selections, laying/adding cards, joker handling and enabled take-back variants, end of turn, recycling, timeout and final hand scoring. |
| Makao | Single and packet play, requested rank/suit, penalties, optional jokers, drawing with/without a playable card, stock recycling and finish. |
| Domino | Starter selection, matching placement, private draw, no legal move, timeout, blocked round, penalties and a new deal. |
| Mexican Train | Initial doubles/starter, own/shared/open trains, unresolved doubles and extra play, draw/pass, blocked round, new round and final totals. |
| Scrabble | Initial rack, several tiles in one word, blank, local/remote draft preview, withdrawal, exchange and possible return of the same tile, mixed-pool bag, exhaustion, pass/timeout and final rack scoring. |
| Biblios | Empty opening hands with pool checks, distribution to self/others/auction, private gifts, public choices, auction bids/payments, transition to final scoring; include at least three accounts. |
| UNO | Opening non-wild card and reserved wild receipts, penalties, colour choice, interceptions, challenge, 0/7 transfers, Flip, No Mercy, timeouts, recycling, round scores and next deal. Cover each supported materially different deck/rule path. |
| Taboo | Describer, guessing teammate, opposing team and spectator; phrase sharing, skipping, timeout, reveal/review/approval, role rotation and a turn crossing a reshuffle. Test ordinary saved games separately. |

Taboo needs a live four-account team trial: the describer and permitted opposing
players receive the same phrase, while the guessing teammate cannot obtain it,
even when that teammate hosts the table. A spectator or a forged addressed
request must not expand the audience. Rejoin must recover the same phrase,
not draw another. Review waits for authentic reveals; missing accounts and a
host change must not fabricate approval or reveal future phrases.

Duck Racing additionally needs a normal multi-lap race with humans and bots:
card effects changing dice, field/card chains, repeated encounters, challenge
timeouts, freezes, lap transitions and finish. Verify a fresh authenticated seed
for every required race/challenge roll, including automatic actions, and no
change in the unlimited card-draw distribution. Couple this with section 3's
spectator tests without exposing challenge secrets to nonparticipants.

### 6.5. Reconnection, host changes, bots and saved games

Run the applicable lifecycle cases separately for each private-hand adapter and
each public-randomness family, rotating the original host and returning player:

- Leave/return before a draw, while a write is pending, after server acceptance
  but before acknowledgement, after a reveal, during scoring and between deals.
  Use both ordinary native leave/rejoin and a controlled test-client shutdown
  followed by a cold start. Restore the same session/account, not a new match.
- Transfer host to another player and, where supported, a spectator while a
  human draw/reveal is in flight. Valid human actions must not be lost solely
  because the host changed; stale host-only actions remain forbidden. No second
  executor, repeated deal, hand leakage or reset of the return allowance.
- In ordinary games, test human-human, human-bot and multiple-bot play where
  supported; replacing a departed player, returning as observer, changing host
  and continuing legal bot moves. No invented bots in games without support.
- Save and restore ordinary games at allowed phases, including after draws,
  exchanges, host changes and recycling. Compare hands, deck/bag order, scores,
  next legal move and subsequent randomness. Cancelled/failed/uncertain restore
  must not delete an unconsumed archive or duplicate the resumed game.
- In tournament private mode, verify bot/replacement and archive routes are
  refused below the UI as well as hidden where appropriate. Rejoining the same
  account within the allowance remains possible; returning after committed
  elimination/forfeit cannot reclaim a seat or submit a late game result.
- Cross the new manual/automatic forfeit path with private operations: pending
  draw, irreversible reveal, incomplete round audit, host transfer and final
  result. No partial private state may become a scored result; no withheld
  disclosure may be replaced by guessed scores or a fabricated empty hand.

### 6.6. Failure injection, limits and performance

- Cover delayed responses, a lost acknowledgement, disconnect/reconnect,
  duplicate/reordered events, temporarily unavailable private reads, partial
  pagination, authorization refusal, 429/backoff and temporary server errors.
  Use scoped test-client faults or local transport doubles where native faults
  cannot be triggered safely. Do not flood the service to manufacture a real
  rate limit or disrupt the user's main connection. Label simulated failures.
- Test pool exhaustion, recycling with several still-held old-pool cards,
  retirement of only eligible pools, and the 32-pool limit. A controlled limit
  error must preserve hands and never downgrade privacy. Fresh rounds retire
  appropriate pools; cold replay still reconstructs earlier public evidence.
  Include ordered-slot games, which must retain their distinct receipt order.
- Exercise long histories, shortened server pages, batch/payload limits and
  bounded caches. Preserve the known LiveSessions history limit rather than
  expanding storage architecture without approval. Limits must produce an
  explicit recoverable/controlled outcome, not silent truncation or corruption.
- Measure startup, table creation, initial deal, ordinary roll/draw/play, fresh
  round, recycle, reconnect, host transfer and result publication. Separate UI
  blocking from background request duration and report request counts, retries,
  queue time, native operation time and visible completion. A slow request
  does not by itself prove that the interface froze.
- For each transport operation family, collect at least 30 normal samples where
  practical and report median, 95th percentile and maximum with sample counts.
  Record cold/warm caches and ordinary/private modes separately, and compare
  against the available pre-change baseline under the same conditions. Identify
  the measured source version; do not invent a baseline or label noise a gain.
- Play and use chat/navigation during delayed requests, while periodic account
  tasks operate normally. Do not rely only on developer mode, which suppresses
  statistics, when claiming smoothness in a release configuration. Use isolated
  test telemetry if needed; do not publish fabricated production statistics.
- Include a sustained multi-round/repeated-table run of at least 30 minutes on
  the real clients, recording pending operations, pool/cache sizes, callbacks,
  thread counts, memory/handles and request rate at intervals. Look for growth
  that persists after own tables close; distinguish transient caches from a
  demonstrated leak. Never force cleanup of unrelated host resources.

### 6.7. Evidence and completion gate

- The user authorizes immediate fixes for confirmed bugs exposed by these
  trials within the agreed scope, without asking for approval for each fix.
  Preserve the failing evidence and isolate the cause first; distinguish a
  product defect from a faulty test or diagnostic helper and repair the actual
  cause. Do not weaken validation, remove guards, skip failing scenarios or
  change game rules merely to obtain a passing result.
- Add a targeted regression for each fix, repeat the original failing live
  scenario and rerun the affected local and live checks on the final sources.
  Include directly dependent behavior, but do not restart unrelated test suites
  after every change. Repeat diagnosis, repair and verification until the
  observed in-scope defects are resolved; record blocked cases explicitly.
  Changes of game rules, wider architectural work and native API limitations
  follow the execution policy above: defer decision-dependent changes to the
  final report without interrupting independent work with questions.
- Reuse and extend the existing targeted tests, including
  `test/transport/server_random_test.rb`, `test/transport/server_random_recipes_test.rb`,
  `test/transport/*private*test.rb` and the relevant tournament, persistence,
  game and native-UI tests. Inspect what each test actually exercises: a name
  containing "private" or "native" does not prove live server-private coverage.
- Give every required matrix row one explicit status: passed, failed, blocked,
  not applicable with a reason, or not run. No skipped/failed/unfinished trial
  counts as a pass. Keep initial failures, their diagnosis, fixes and final
  reruns; count aggregate tests separately from their child scenarios.
- For each live scenario retain the input route, normal UI steps, accepted
  event/operation boundaries, relevant account-specific observations, expected
  and actual outcome, and cleanup result. Redact private credentials and do not
  log other users' secrets. Store reports under the repository's ignored `tmp/`
  directory, not in the installer or public repository.
- Compare final public state across accounts and private projections only for
  the rightful owner/permitted audience. Record both confidentiality failures
  and inability to recover legitimate private state; hiding cards is not enough
  if their owner can no longer finish the game.
- Before calling the planned work ready, resolve every observed regression in
  scope, rerun affected scenarios on the final sources and disclose any native
  API limit or missing live configuration. Report supported modes separately
  from intentional disclosures and unsupported security guarantees. If testing
  exposes a change of rules or a wider architectural requirement, leave the
  decision-dependent change unimplemented and record it for the final report,
  rather than asking mid-work or changing the game to make the test pass.
- Run the final clean live smoke through real menus and game controls after
  removing probes. Package/signature/update checks belong to a separately
  requested build, using its exact bytes; source tests must not be described as
  package verification. A test-only unprotected application must not be used
  as proof of production authorization or signed-release behavior.

## 7. Whole-project audit: correctness, performance and maintainability

Confirmed additional scope: after implementing the agreed features, integrating
the pull requests under section 9 and verifying the combined result, audit the
entire current Power Games codebase, not just the new
features, recently changed files or previously reported problems. Findings from
the earlier implementation/tests must be repaired as they arise; do not defer
known defects merely because the dedicated audit has not started yet.

The user requests line-by-line review, immediate fixes, local and live tests,
and repeated complete reviews until no further justified findings emerge.
One partial audit, a search for familiar patterns or a passing test suite is
not completion. This section explicitly adds project-wide bug fixes, justified
optimizations and code cleanup to the implementation scope of this plan.

### 7.1. Inventory and complete reading coverage

- Record the starting revision and existing uncommitted work. Inventory every
  maintained source file, including application entry points, every game and
  bot, shared UI/presentation, transport, randomness/private state, persistence,
  tournaments, statistics, content loaders, settings, notifications, tools,
  tests, test helpers, build scripts and CI configuration.
- Read each maintained source file in full, line by line and in context. Trace
  its callers, callbacks, state ownership and effects across module boundaries.
  A file is not reviewed merely because a search or test touched it. Record
  reviewed files/sections, source hashes, findings and outstanding questions in
  an audit ledger under ignored `tmp/`; do not infer coverage from line counts.
- Check generated code against its maintained inputs and generation rules;
  repair the source of truth rather than hand-editing generated output. Review
  resource declarations, translations and packaging references for functional
  correctness. Do not claim to read binary assets line by line or turn a code
  audit into an unrelated rewrite of questions, rulebooks or recordings.
- Prioritize high-risk shared paths, but then cover every remaining module.
  Revisit callers and consumers when a shared fix changes their assumptions.
  Mark affected earlier coverage stale until the final source version has been
  reviewed and tested again. Newly added files enter the same inventory.
- Use ELTEN sources and documented server contracts to identify the responsible
  layer. Do not silently merge separate experimental branches, modify the host
  or server, or count unavailable external code as reviewed Power Games code.

### 7.2. Three required review tracks

1. **Bugs and correctness.** Check validation, permissions, private information,
   game rules and scoring, state transitions, defaults, bounds, null/empty
   values, encodings and error propagation. Trace concurrency, stale callbacks,
   host/participant changes, idempotency, lost acknowledgements, replay, saves,
   resource cleanup and lifecycle across reloads. Include actual UI focus,
   shortcuts, chat, speech/audio, covered windows, supported languages, bots and
   ordinary/tournament differences. Test suspicious paths rather than declaring
   them correct because an existing test passes or an exception is rescued.
2. **Possible optimizations.** Look for redundant requests, repeated reads or
   parsing, unnecessary replay/projection work, copying and allocations,
   expensive searches, oversized payloads, unbounded caches/queues, lock
   contention, retained callbacks/threads/handles and blocking UI work. Measure
   relevant paths before and after under comparable conditions using section
   6.6's metrics. Preserve freshness, ordering, privacy, deterministic results,
   acknowledgements and useful diagnostics. A smaller diff, fewer lines or a
   single faster run does not establish a performance improvement.
3. **Cleanup and clarity.** Find genuinely unused code, unreachable branches,
   obsolete workarounds and compatibility layers, redundant wrappers,
   duplicated or near-duplicated logic, contradictory responsibilities,
   misleading names/comments and test helpers that hide product behavior.
   Prefer the existing shared framework and clear ownership to per-game copies
   or new parallel mechanisms. Similar-looking code is not automatically the
   same contract; do not combine behavior that must remain distinct.

Use Dawid Pieper's cleanup as a concrete reference: inspect the actual changes
in `f2f6ae6` ("Make global cleanup") and their integration through PR #28 in
`2a3b36d`, including what the build 241 integration retained or adapted. This
is a model for useful simplification, not an instruction to reapply an old diff,
restore old behavior or maximize deletions. New, well-supported improvements
are welcome. Existing current contracts take precedence over historical code.

The correctness track also includes usability and accessible feedback, not
only exceptions and final state. Inspect the complete interaction for each
changed control and analogous controls throughout the project:

- Is it clear what the user can do and which key performs it, without needing
  to discover a hidden confirmation requirement by trial and error?
- Can the user distinguish a highlighted choice, an unsubmitted edit, an
  accepted change, a pending write and a rejected action?
- Does a completed action give concise, truthful feedback to its initiator,
  without flooding other participants, repeating the whole list, stealing
  focus or placing temporary instructions in permanent history?
- Are hints placed with the relevant item and read once on intentional focus,
  not after every arrow key, refresh, reconnect or background update?
- Do success, failure and timer cues follow actual state transitions, remain
  usable with a screen reader and work consistently in supported languages?

Countries and Cities review (arrows choose, Enter confirms) is the concrete
regression example, not the limit of this audit. Use native controls and real
account interactions to verify the behavior. Do not treat a handler returning
success or a generated speech string alone as proof of usable spoken feedback.

Before removing apparently unused code, check dynamic registration, reflection,
callbacks, generated references, packaging and supported saved/event formats;
an empty textual-reference search is insufficient. Remove the corresponding
obsolete wiring and tests only when their contract is genuinely obsolete, and
update maintenance documentation. Do not introduce speculative abstractions,
fallbacks or wholesale formatting churn merely to have something to clean up.

### 7.3. Immediate repair and verification cycle

- For every finding, keep the location, evidence, affected behavior, cause,
  proposed correction and required regression coverage. Separate demonstrated
  bugs, measured optimization opportunities and justified cleanup from guesses.
  Investigate uncertain behavior through controlled local and live trials.
- Fix confirmed bugs and justified improvements as they are found, without
  asking for separate approval for each in-scope correction. Work in small,
  coherent batches so a regression can be attributed to a particular change;
  preserve the user's unrelated working changes. Do not accumulate a report
  of known fixable defects while presenting the audit as completed work.
- Add or strengthen a regression that exercises the real failing path. Where
  practical, verify that it fails against the pre-fix behavior. Preserve initial
  failures, and repair faulty fixtures/helpers separately from product code.
  Do not relax assertions, hide errors or delete safeguards to obtain a pass.
- After each batch, run the affected local checks and exercise changed runtime
  behavior on real accounts, following sections 5 and 6. Repeat the original
  failure and the relevant normal, boundary and recovery cases. Shared changes
  require checks of their affected consumers/game families, not only the game
  that first exposed the issue. Ordinary play, bots, saves and tournaments must
  retain their documented behavior wherever supported.
- Use real menus, controls and legal play as the primary live evidence. Include
  complete affected matches, host changes/rejoins and private-hand checks where
  relevant. Functional cleanup still requires behavioral regression checks;
  optimization additionally requires comparable timing/request/resource data.
  Test-only or tooling changes use their real execution path; do not invent a
  live-game test for code that never runs in a client. Record that distinction.
- Reinspect every fix and its dependent paths, then continue the full review.
  If testing reveals another problem, repeat diagnosis, repair and verification
  before closing that finding. Rerun affected tests, not every unrelated suite
  after every edit. A final green result from older sources does not cover a
  subsequent cleanup or optimization.
- Update technical contracts and relevant user-facing documentation in all
  supported languages when a correction changes documented behavior. Preserve
  creator-supplied text restrictions and the agreed game rules. New game rules,
  external server/API work or a fundamental architecture replacement not
  already agreed here belong on the final decision list, without implementation
  or questions during the work. Continue independent tasks; document a
  demonstrated external limitation rather than concealing it with a new
  workaround or claiming it fixed.

### 7.4. Additional defect-finding and improvement methods

These methods supplement complete source review and normal live play. Reuse
existing contract helpers, replay fixtures and benchmark tools where suitable;
do not create a second production implementation or a parallel game executor.

#### Compare old and new behavior on the same inputs

- Preserve a baseline of the actual working sources before a coherent change,
  including existing uncommitted fixes, rather than assuming Git HEAD is the
  user's current version. Feed both implementations identical recorded events,
  options, participants, clocks and accepted random receipts in isolation.
- Compare states, legal actions, scores, card ownership/order, subsequent RNG
  state where relevant, and presentation effects. Check full replay against
  incremental/cached replay too. Document intended differences for verified
  bug fixes: old behavior is a reference, not an infallible correctness oracle.
- Never perform a real write twice for comparison. Use copied inputs and
  isolated fixtures for differential runs; each live match has one active
  implementation and its normal writer. Avoid logging private data outside
  the controlled accounts' appropriate diagnostic scope.

#### Check invariants throughout a scenario

- Specify properties that must hold after every relevant transition, not only
  at match end: finite decks conserve physical card identities, an accepted
  action/result is applied once, only the current authorized player can act,
  spectators cannot play, and replay reconstructs the same accepted state.
- Make properties match the actual game: identical faces are not duplicated
  physical cards, with-replacement draws are allowed where specified, and
  scoring need not conserve a fixed total. Include private ownership, resource
  lifetime and control-epoch invariants as well as game-model properties.
- Test equivalent paths, such as cold versus warm replay or duplicate delivery
  versus single delivery, for the same outcome. Harmless UI navigation must
  not change the game; a cache optimization must not suppress an event.

#### Generate reproducible sequences beyond hand-written examples

- Run bounded, seeded local sequences of legal moves and controlled invalid
  actions, host changes, disconnects, retries and phase transitions. Vary
  supported options and roles; supplement focused combinations with pairwise
  combinations where an exhaustive option product is impractical. Do not label
  sampled or pairwise coverage exhaustive.
- Retain failing seeds and operation schedules. Reduce a failing sequence to
  its smallest useful reproduction, add a durable regression, then reproduce
  the relevant behavior on live accounts. High-volume generation belongs in
  local fixtures, not repeated traffic against the public server.

#### Control the exact ordering of concurrent events

- Use explicit barriers and controllable test clocks to exercise both orders
  around acceptance, acknowledgement, timeout, host transfer, result writing
  and closure. Include the interval between a permission check and its write.
  Do not rely on arbitrary sleeps or one lucky real-time run to cover a race.
- Cross operations that share resources: chat versus chat, chat versus moves
  or points, answering versus refresh, and reconnect versus an uncertain write.
  Section 8 provides concrete user-reported acceptance scenarios. Verify each
  critical local schedule and repeat representative native/live reproductions.

#### Verify that tests can detect the defects they claim to cover

- In an isolated local test process or disposable source copy, temporarily
  restore the faulty behavior or introduce a narrow representative defect.
  Confirm the relevant test fails for the intended reason. Never put a mutation
  into a user's running client or leave it in the product sources.
- Review test doubles against native contracts, test order dependence, leaked
  global state, swallowed exceptions, stale fixtures and assertions that merely
  check a helper's own output. A test must observe the actual consequence, not
  manufacture the expected acknowledgement or bypass the failing path.
- Use existing real test entry points. For affected tooling/CI tests check
  clean-checkout assumptions, declared dependencies and environment differences;
  local hidden files or tool caches must not be necessary for a passing result.

#### Keep performance regressions detectable

- Add targeted budgets for requests, repeated projections/parses, copies,
  retained queues/resources and growth with small, medium and large histories.
  Reuse existing read-budget and benchmark helpers. A gain at startup must not
  become slower long-game replay or a growing cache.
- Compare cold/warm cases and multiple samples under the same conditions.
  Prefer deterministic operation-count/growth checks in automated tests;
  report timing distributions without brittle machine-independent millisecond
  assertions. Check CPU, memory, responsiveness and request cost together so
  an apparent gain does not merely move work elsewhere or reduce correctness.

#### Try better internal implementations with an explicit acceptance gate

- Allow coherent algorithm replacements, removal of a redundant layer and
  consolidation of genuinely shared behavior within the current architecture,
  without asking about each experiment. Before changing it, record the target
  problem, preserved contracts, comparison method and safe rollback boundary.
- Keep a candidate only if it fixes the demonstrated problem or offers a
  repeatable resource/performance gain or concrete maintainability benefit,
  such as one source of a rule instead of duplicated implementations. Fewer
  lines alone are not proof; state the trade-offs and verify dependent paths.
- Require appropriate local regressions and live checks with no unexplained
  behavior differences, privacy loss, weaker validation or material regression
  in another operation. Remove unsuccessful experiments and temporary switches
  from production; revert only the experiment's own changes, preserving the
  user's work and other confirmed fixes. Keep useful evidence outside runtime.
- Major changes to game behavior, rules or fundamental architecture still go
  to the final decision list. Do not broaden an experiment's authority merely
  because its first measurements look promising.

### 7.5. Broad audit stopped; focused completion criteria

- Latest user decision, 18 October 2026: stop the broad audit immediately,
  without finishing the unread remainder of 1-f. Record already completed
  reads, but do not start another full inventory review or rotation. This
  replaces both the clean-pass requirements and the later requirement to
  finish the current pass regardless of its verdict.
- Resolve confirmed in-scope defects and complete the already agreed features.
  Review changed paths and run their relevant local/live regressions, but do
  not restart the full audit after each fix. Do not expand the work with new
  optional cleanup, cosmetic edits or speculative optimizations.
- Account for actual coverage honestly: a finding makes this pass non-clean,
  and an unread area is not reviewed. Neither needs to be relabeled to satisfy
  a clean-pass requirement that the user has now explicitly withdrawn.
- Finish the agreed implementation and resolve confirmed in-scope findings.
  Reuse earlier valid tests; add only checks for new changes, their direct
  dependencies and genuinely missing acceptance boundaries. Do not repeat
  full game campaigns merely because an evidence index lists an unfinished
  variant or lacks a cross-reference. The user also ended the long UNO trial;
  preserve its completed games and do not restart that trial.
- Run affected local/live checks against the final relevant sources, remove
  temporary probes, and perform a bounded final smoke check through normal
  controls. Record untested variants and unread audit areas honestly; they no
  longer require completion of the cancelled exhaustive review. Final CI,
  signed package verification and GitHub publication remain required.
- Acceptance also requires the independent code and test-evidence reviews in
  section 7.6. An author's own review or a green result reported without
  inspecting its coverage is not a substitute for those checks.
- Provide a concise summary of fixes, measured gains, removed duplication or
  obsolete mechanisms, actual live coverage and any remaining limitations.
  Include the deferred decision list required by the execution policy. A
  completed review can still identify unresolved major changes; label those
  explicitly and do not count them as fixed or their dependent tests as passed.
  Keep the detailed per-file/per-pass ledger and original/final evidence in
  ignored `tmp/`. Distinguish a complete review of the documented scope from a
  guarantee that no possible bug exists; neither repeated audits nor live
  trials can establish such a guarantee.

### 7.6. Quality-focused multi-agent work

Use a coordinating agent and up to three supporting agents, within the actual
available capacity. Organize work into coherent changes with independent
review, rather than assigning four unrelated parts and assuming their union
is correct. If fewer slots are available, run the roles sequentially without
dropping independent verification. Do not launch agents just to edit this plan.

#### Responsibilities

- Implementation agent: establish a reproducible cause, prepare the smallest
  coherent fix and its regression tests, and document affected contracts and
  remaining risks. Own an explicitly assigned code area; do not approve the
  final acceptance of your own change.
- Independent code reviewer: first read the agreed requirements and relevant
  source/dependency paths and form an independent account of the behavior.
  Then inspect the proposed fix and its explanation. Challenge assumptions,
  seek alternative causes and counterexamples, and check privacy, authority,
  replay, failure handling and compatibility with the existing framework.
  Do not limit review to the changed lines or the author's list of risks.
- Independent test and performance reviewer: derive expected outcomes and
  missing scenarios from the contracts, inspect assertions and test doubles,
  and run relevant checks. Verify that tests detect the original defect where
  safely reproducible, using a recorded baseline or controlled local mutation
  as appropriate. Check final behavior, realistic failure paths and measured
  costs, not just whether the implementer's tests return green. Never inject
  faulty code into live clients for a negative control.
- Coordinator: retain the full requirements and coverage ledger, assign
  ownership, resolve contradictions using evidence, integrate changes and
  control live-account tests. Check interactions between areas and make the
  final acceptance decision. For coordinator-authored changes, supporting
  agents still provide the independent code and test reviews.

#### Independent findings and acceptance

- Supply every agent with the complete applicable instructions, agreed scope,
  relevant contracts, baseline identity and boundaries of authority. Preserve
  an independent first assessment without withholding essential requirements
  or known safety constraints. Reviewers must not merely repeat the author's
  diagnosis or infer correctness from agreement between agents.
- Each finding must identify the source location, expected and observed
  behavior, reproduction or other concrete evidence, severity and uncertainty.
  Resolve disagreements by inspecting code or running a discriminating test,
  not by majority vote. Unresolved consequential issues remain visible in the
  final decision or coverage list under the existing execution policy.
- Shared synchronization, input gating, server randomness, private hands,
  tournament results, saved games and host/controller changes require explicit
  cross-module review. Give these paths overlapping scrutiny even when their
  files belong to different implementation assignments.
- Record source hashes, commands, environment and original/final results for
  each review and test batch. Inspect the evidence rather than copying another
  agent's PASS summary. Distinguish local models, real-account API calls,
  native handlers, keyboard interaction and actual speech/audio observations.
- A change after review invalidates the verdict for the affected code and
  dependencies. Re-review those paths and rerun their affected checks against
  the final integrated sources. If a reviewer implements a fix, another agent
  must independently review it; their earlier reviewer role is not approval.
- The broad assignments are stopped under section 7.5; agents now perform
  only implementation and focused independent acceptance of affected paths.
  Three agents reviewing separate thirds of the inventory constitute at most
  one complete pass, not three. The coordinator checks the boundaries between
  them; multiple agents do not establish a guarantee that every defect was found.

#### Shared-workspace and live-test coordination

- Assign one writer to each file or tightly coupled area at a time. Reviewers
  are read-only by default; agree test-file ownership before making edits.
  Shared checkouts are not isolation: preserve unrelated changes and inspect
  the integrated diff before accepting any batch.
- Maintain one live-test schedule with explicit ownership of each client,
  account, table and temporary resource. The coordinator controls live tests
  by default. Delegate a live scenario only with exclusive resource ownership;
  no agent may independently navigate, reload, close or mutate another agent's
  active client/table. Parallel source review and isolated local tests may
  continue, but stop competing workloads during latency or resource benchmarks.
- Delegation does not expand permission to change server protection, schemas,
  quotas, installations, packages, versions or GitHub state. Apply the same
  scope and cleanup rules to all agents, preserve evidence and remove only
  resources belonging to the agreed trials.
- Use focused handoffs and bounded work batches, not ever more agents or
  repeated broad scans without new evidence. Inherit the selected model and
  reasoning effort unless explicitly directed otherwise. Ultra is optional:
  it does not replace independent review, realistic tests or coordination,
  and the workflow must not depend on an assumed increase in available slots.

## 8. Concurrent input: chat, moves, points and challenge answers

### 8.1. Reported symptoms and confirmed design requirement

The user reports that when two people send table-chat messages at nearly the
same time, one can hear "Proszę czekać" ("Please wait") and their message is
not sent. Similar behavior occurs when another player plays a card or a point
is recorded. Duck Racing can announce waiting while entering challenge input;
the user has also heard it in Pong, without identifying the exact operation.
These are reported reproductions to investigate, not yet a demonstrated shared
root cause. Track each separately rather than assuming one fix covers them all.

Confirmed requirement: block only actions that actually conflict with an
unfinished operation, not the entire game interface automatically. Serializing
writes does not itself justify blocking editing, navigation or independent
chat. Preserve necessary exclusion of duplicate/stale game actions and the
existing shared executor; do not remove all waiting guards indiscriminately.

Work on this reported behavior during implementation, before closing the
whole-project audit. Apply sections 5-7's evidence and no-question policies.

Additional user reproduction: rapidly adding several computers also loses
commands behind "Please wait". Include waiting rooms and finished-game screens,
not just chat or moves. Keep membership writes serialized, but retain a bounded
number of explicit add/remove intentions, with fresh capacity, owner, match and
participant checks before each execution. Never remove a different computer
because the selected row moved. Discard unexecuted intentions on departure,
rematch, account/membership change or an uncertain write; do not replay them in
another room. Test the full-table boundary and continued normal play on live
accounts. Audit the remaining command gates by their actual conflict, not by
the presence of any background task.

The user also reports smoother rapid UNO play. Trace this against the confirmed
snapshot/presentation path and record the evidence; do not attribute it to
weakened validation or assume that it proves other controls are responsive.

### 8.2. Trace the cause and narrow the blocking boundary

- Map input capture, control activation, task/queue admission, synchronization,
  native append, acknowledgement, replay and presentation for every symptom.
  Record which guard emits each waiting message and whether the input was
  rejected, retained, queued, accepted, or merely not yet displayed.
- Inspect the existing shared paths first: `lib/game_room_pending_operation.rb`,
  `lib/game_screen/input.rb`, `GameScreen#submit_chat` in `lib/game_screen.rb`,
  the synchronizer/session runner and `lib/realtime/task_ui.rb`. For Duck Racing,
  include the challenge client and `concurrent_session_input?` contract. These
  are investigation targets, not proof of the cause or instructions to bypass
  their guards. Check native ELTEN task behavior where the evidence leads there.
- Establish the actual conflict scope: table membership, game/round/challenge,
  participant/controller epoch, selected action and outstanding write identity.
  Distinguish a remote chat append or presentation refresh from a game-state
  change that genuinely invalidates the selected move. Keep final validation.
- Reuse the existing task/writer/framework contracts for any necessary
  per-operation admission or bounded pending input. Do not introduce another
  game executor, polling loop or unbounded generic action queue. A local action
  waiting for one writer slot need not disable every control in that window.
- Local editing, cursor navigation and safe read-only commands stay usable.
  Chat admission must not discard a valid message solely because unrelated
  game activity or another person's chat is being processed. Accepting an
  independent send intention need not mean issuing simultaneous native writes.
  Revalidate membership and destination when sending; never deliver a pending
  message to a different table after leaving or switching games.
- Preserve the submitted text separately from later edits. Clear only the
  acknowledged draft generation; an old completion must not erase newly typed
  text. Retain unsent content on failure, reconcile uncertain outcomes before
  retrying, and avoid duplicate messages/sounds/history after repeated Enter.
  This concerns pending in-session input, not a new persistent outbox feature.
- For challenge input, preserve focus, partially entered digits/text, the final
  digit's submission and any private response across unrelated refreshes.
  Confirm acceptance in the same challenge/attempt through existing validation.
  Do not carry an answer into the next challenge, replay stale game actions,
  extend deadlines or backdate an answer to compensate for local waiting.
- In Pong, distinguish actual synchronization/recovery from a generic task
  notice. Verify input, physics and audio continue through unrelated chat and
  durable point writes as their existing contracts allow. Do not change rally
  rules, scoring or physics to hide a task/UI problem. Keep necessary blocking
  where the authoritative result of a conflicting action remains unknown.
- Reduce avoidable waiting at its cause; merely suppressing the announcement
  while still dropping a message or answer is not a fix. Explain a legitimate
  failure without repeated announcements or claiming an unsent input succeeded.

### 8.3. Required local and live acceptance scenarios

- Two and then three/four real accounts submit distinct chat messages nearly
  simultaneously, using normal controls. Repeat with reversed timing, repeated
  Enter, a second draft typed while the first is pending, and delayed/lost
  acknowledgements. Verify one accepted copy of each intended message on all
  clients, correct authors, preserved newer drafts and no unsolicited resend.
- Cross chat with a legal card play/draw, a human or bot turn, a round result,
  and a Pong point. Exercise the same client's competing actions as well as
  remote actions, including ordinary and tournament/private-hand paths where
  relevant. Repeat message/replay delivery without duplicating effects.
- In each affected Duck challenge input mode, type during another submission,
  chat delivery, preparation/result upload and a view refresh. Check automatic
  final-digit submission as well as explicit submission where used. Test the
  actual timeout boundary, changed challenge and focus switching; distinguish
  intended pre-start restrictions from input lost during an active attempt.
- Check Pong player and spectator-host cases, chat during rallies and point
  settlement, plus return from a covered window. If a shared realtime adapter
  changes, include the corresponding Audio Ball paths rather than assuming
  Pong coverage is enough.
- Exercise leave/rejoin, host transfer, table closure and a new game with a
  send pending. No cross-table message, old-answer replay, stale draft clearing
  or unlocking of a newer operation. Keep deliberate duplicate/illegal moves
  rejected: making chat responsive must not weaken move authorization.
- Extend existing pending-operation, chat, challenge-input and runner tests
  rather than replacing them with superficial send-success checks. Retain a
  failing baseline for reproduced defects and compare queue delay, UI blocking,
  network time and request counts after the fix. Label simulations, incomplete
  reproductions and untested cases accurately; only then close each symptom.

## 9. Open pull requests: audit, integration and full affected verification

Confirmed addition: include the open GitHub pull requests in this implementation,
not as a separate unchecked change after the audit. Integrate them before the
final whole-project review in section 7. Extend section 6's per-game matrix with
the new game and any additional randomness or private-state paths.

### 9.1. Reviewed inputs and integration order

- The open-PR inventory checked on 18 October 2026 contains:
  - [PR #36 — Bridge](https://github.com/papierek1997/elten-game-room/pull/36),
    head `a6f469d5844be53027763e7592f1d0dd7b506df9`.
  - [PR #37 — poker announcements and betting sounds](https://github.com/papierek1997/elten-game-room/pull/37),
    head `dcd6038f66ca5a8a0f0b492ea4b6f0e5022ed576`.
- The maintainer subsequently authorized the HRTF handoff from
  [PR #38](https://github.com/papierek1997/elten-game-room/pull/38): commits
  `96bb885a96833192ece6603c1965f4070afb65a1` and
  `33604f0dfddbde29d77b3c16bd8c5a02bf413f1e`. Integrate only that delta;
  the preceding poker commit is already covered by PR #37. Verify spatial
  placement, ordinary-audio fallback, mute/volume behavior, settings and
  translated documentation. This does not authorize a fresh broad audit.
- Record the exact base, reviewed head, changed files, CI findings and local
  working-source hashes. Refresh remote metadata before integration; if the
  author changes the head, review the additional changes instead of silently
  replacing reviewed code. PR descriptions and claimed test results are leads,
  not proof of correctness or compatibility.
- Finish or freeze overlapping work from sections 1-4 and 8 before modifying
  the same shared files. Review each PR independently, adapt it to the current
  working sources, then test the combined version. Preserve existing local
  work; do not replace whole files with the PR's older versions or blindly merge.
- Import the intended functionality into the existing skeleton: presentation,
  controls, executor, clock, randomness, private cards, bots, saved ordinary
  games, tournament restrictions, translations and resource registration.
  Resolve conflicts by contract and behavior, not only by textual merge success.

### 9.2. Full PR audit and repairs

- Read every changed maintained source file in full and trace its callers and
  dependents. Inspect tests, fixtures, documentation, translations, resources
  and build declarations too. Apply the three review tracks and immediate
  repair cycle from section 7; include unchanged shared code whose assumptions
  are affected. Have an independent agent check the adaptations and evidence.
- For Bridge, verify auction legality, declaring and dummy control, turn
  ownership, playing to suit, scoring, ties, passed-out deals, partnerships,
  bots, ordinary saves, return and host transfer. Check the proposed duplicate
  reference-score mechanism rather than treating an HCP estimate as actual
  results from other tables. Record any substantial unresolved rules decision
  under the execution policy; do not invent a competitive scoring contract.
- Bring Bridge's public randomness and tournament private hands into the
  already implemented framework. A PR based on public deal seeds must not
  reintroduce publicly recoverable tournament hands. Verify when dummy becomes
  public, who may control it, and that ordinary bots and saves still work.
- For poker, verify private versus public announcements, betting sounds by
  accepted effect, timeouts, side pots and showdown ordering. Check the proposed
  inter-deal delay against the current executor and pause clock: reconnecting,
  changing host, refreshing a view or replaying history must not reset it,
  bypass it, repeat audio or block unrelated chat and input.
- Inspect the shared number-input change in other affected games, including
  invalid input, cancellation, focus restoration and retained input. Verify
  actual CI failures against the appropriate baseline; do not assume they are
  unrelated merely because the PR says so. Check audio licensing and credits.

### 9.3. Rules and player documentation for the new game

- Read the current rule-writing template and editorial instructions. Rewrite
  the new game's rules naturally in every supported language, checking them
  against the verified implementation rather than mechanically translating.
- Explain the goal, normal flow, required controls and scoring in a usable
  order; keep optional variants separate. Use familiar language, clear headings
  and Markdown lists for enumerations. Avoid redundant technical explanations,
  artificial phrasing, mixed languages and controls mentioned only in a final
  shortcut list. Follow the user's explicit request to edit these PR rules.
- Update maintained rulebook sources and regenerate derived files. Check
  option/shortcut coverage, language correctness, encoding and generated output;
  update affected multilingual README descriptions without overwriting other
  edits or changing the agreed release metadata as a side effect.

### 9.4. Acceptance gate

- Apply sections 5-8's local and live-test standards to all affected PR paths,
  not just the new game. Include normal full play, valid and rejected actions,
  multiple human accounts, spectators, bots, ordinary saves, host changes,
  disconnect/return, tournament results and restrictions, private-hand access,
  concurrency, retries, clocks, announcements and sounds where applicable.
- Add targeted regressions for findings and retain failing controls. Then
  verify the integrated version and run the relevant CI checks locally. Record
  scenario, accounts, source hashes, results and limitations; a PR's previous
  green checks do not validate our adapted working tree.
- Include all imported files and affected shared modules in the final audit
  inventory. A subsequent fix invalidates the corresponding earlier review and
  test coverage until rechecked. Do not declare completion with known fixable
  regressions, unreviewed PR code or required live tests still pending.

## 10. Final release: 2.0.5.1 rebuild and GitHub verification

Confirmed addition: perform this stage after the implementation, PR integration,
required tests and iterative audit above. Do not publish an intermediate working
tree or imply that updating this plan completes any of its acceptance gates.

- Update the changelog for version 2.0.5.1 / build 252 with the changes actually
  delivered. Keep it player-facing, with the applicable language versions in
  sync; explain new features and visible fixes, not internal implementation
  details. Retain the agreed credits and distinguish any deferred scope.
- Run the repository's GitHub CI checks against the final integrated sources
  before publishing, using the required host source and supported environments.
  Inspect failures and fix their causes. Correct obsolete fixtures or brittle
  tests where justified, but do not disable checks, skip required scenarios,
  weaken assertions or hide application regressions just to obtain green CI.
  Rerun the affected tests after every correction and the final CI gates after
  integration; preserve original failures and final evidence.
- Rebuild the existing version 2.0.5.1 / build 252 package and sign it with the
  maintainer's usual certificate. Use the normal release configuration, without
  optional developer tools or challenge laboratory. Verify the signature,
  manifest, changelog, resources and source/package consistency under the
  existing packaging procedure. Do not silently increase the version or build.
- Replace the previous package of this same release only after the new signed
  artifact has been successfully built and verified. Resolve the exact obsolete
  artifact paths first; remove only those superseded copies, not other builds,
  source directories or unrelated packages. Leave one current release package
  in the usual output location and report the replaced files.
- Inspect the complete final diff, including pre-existing in-scope changes,
  generated resources and translations. Exclude private diagnostic logs, test
  account data, credentials, signing keys and ignored temporary files. Commit
  and push the completed source changes to the existing GitHub main branch
  without force-pushing or rewriting unrelated history.
- Verify the remote commit and the GitHub Actions run for that exact commit.
  If CI fails, diagnose and repair the cause, rerun relevant local checks and
  push the correction, then check the replacement run. If a correction changes
  packaged application files, rebuild and replace the signed package again so
  the delivered artifact matches the final published source. Report any genuine
  external blocker rather than calling an incomplete or unavailable check a pass.
- Finish with the package path, version/build, published commit and observed CI
  result, plus the concise remaining limitations/decisions from the audit.

The user authorizes this final rebuild, signing, replacement of the previous
same-release package and GitHub source publication. This does not authorize a
GitHub Release upload, PR closure, forum posts or production server schema,
protection or quota changes. Updating this document is not evidence that the
implementation, audit, release or CI verification has already been completed.

## 11. Invitation blacklist added before release

- Add a local Blacklist under notification settings, with Ctrl+N to add a
  user name and Delete to remove it. Save and Cancel follow the existing
  settings form; compare user names without regard to case.
- Hide ordinary invitations from listed senders in notifications, pending
  invitation lists, widget actions and shortcuts. Recheck an invitation
  opened before the blacklist changed. Do not reject or revoke it on the
  server or notify the sender about the blacklist.
- Tournament-match invitations are exempt, using existing invitation/table
  metadata rather than the displayed table name. Preserve normal joining
  checks and the separately configured notification preferences.
- Reuse the existing cached settings and invitation paths, without extra
  polling or network requests. Update all player-facing language editions.
- The maintainer expressly excluded further live trials for this addition;
  verify the affected local regressions instead.
