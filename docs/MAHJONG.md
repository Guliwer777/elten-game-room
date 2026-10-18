# Mahjong integration contract

The requested player entry is one game, **Mahjong**, with a variant setting:
Solitaire, Hong Kong Old Style, Japanese Riichi and Mahjong Competition Rules
(MCR). Solitaire occupies one seat. Hong Kong and MCR occupy four. Riichi
offers four seats or three-seat sanma. Human accounts can fill some seats;
ordinary game bots fill the remaining seats explicitly. A two-human game must
not silently change a four-seat ruleset into an invented two-seat variant.

The components live in `games/mahjong_support/`. `games/mahjong.rb` now provides
the common facade and selects the adapter from the recorded variant. The
testing branch registers one Mahjong catalog entry. An unsigned local-test
installer is built on Power Games 2.0.5; it is not a published release or live
multi-client acceptance.

## Shared tiles and hand interpretation

`Tiles` assigns each physical tile a stable integer identifier. Suited tiles
and honors have four copies; flowers and seasons are distinct bonus tiles.
Solitaire matches any two flowers together and any two seasons together, but
never a flower with a season. Sanma removes characters 2 through 8.

`Hand` enumerates all ordinary winning decompositions, seven pairs and
thirteen orphans. It preserves alternate decompositions and winning-tile
locations so scoring can choose a valid highest-value interpretation. Riichi
requires seven distinct pairs; the Chinese profiles permit a quad as two
pairs. `MCRShapes` adds knitted straights and lesser/greater knitted honors.

`Rules` validates seat profiles. It describes missing seats but does not create
bot controllers or alter room membership.

## Solitaire

`Solitaire` implements flat and layered 144-tile layouts. A free tile has no
overlapping tile above it and at least one free horizontal side. New seeded
deals are assigned along a verified geometrically legal pair-removal order.
This proves that a fresh puzzle is solvable; it does not guarantee that every
choice preserves a solution. Removing a pair returns a new immutable snapshot.
The internal session adapter records the deal seed and accepted pair removals,
supports undo with a monotonically increasing action generation, and reconstructs
the same board through the shared save archive. Compact JSON events fit the
64-byte transport/archive limit. Archive validation does not borrow an active
session identity; resumed live actions require the new session context.

The shared native layered tile grid exposes individual tiles and progress,
never pre-matched pairs. Digits select the layer, arrows move columns/rows,
and D reads coordinates on demand. Tile labels report free left/right/both
sides, blocked sides, or a covered face. Enter marks the first tile locally;
a second matching free tile emits the existing compact pair-removal action.
Mismatches do not write. Selecting the same tile or Escape cancels the local
choice; a changed replay epoch or observer role clears it. Native controls are
reused across refreshes. Covered faces stay hidden and spectators cannot select.
Native control tests pass
in EN/PL/CS/ES/RU with compiled translations. There is no reshuffle or hint.
These checks are isolated integration checks, not a live user acceptance test.
The real shared session executor also passes an entire 72-pair puzzle through
the native LiveSessions test fixture: one automatic deal, exactly 72 accepted
human moves, final room status, stale-screen rejection and feed cleanup. This
is a transport fixture check, not a live server test.
The Solitaire rulebook is connected through `MahjongSolitaireGame`, generated
from complete EN/PL/CS/ES/RU sources under `tools/data/rulebooks/`. It teaches
matching, blocking, pair selection, undo, finishing, layouts and actual keyboard
controls. It selects chapters from the same canonical Mahjong book as the
table variants. The table chapters explain hand construction, open/closed
sets, HK fan and capped payments, Riichi yaku/fu/payments, MCR kong scoring
and minimum fan, and the distinction between hands, seat winds and wind rounds.
Their numerical examples describe the implemented profiles, not a claim of
complete certification against every competition ruleset.

All available action controls follow status and precede the private hand in
all table variants, including draw/win, kong/riichi choices and next-hand ready.
The facade declares a layout decision-focus part, optional selected-list index
and stable session/hand/generation/viewer key. Shared layout applies it once while in game
fields, preserving chat/history/users. The existing speech queue finishes tile
announcements before presenting the response control. The response header
retains the tile context; public melds remain in one owner-labelled field.
The new personal draw phase focuses Draw; after a draw, the hand list focuses
the actual physical drawn tile without discarding it. Same-boundary refreshes
preserve manual browsing. Rulebooks now teach Solitaire, HK, Riichi and MCR in
sequential standalone parts, each table part restarting with its own glossary,
turn walkthrough, complete-hand example and scoring requirements.

The books follow the upstream `docs/RULES_EDITORIAL.md` outline: aim,
preparation, play, scoring/ending, optional settings, then individual shortcut
rows. The 2026-10-17 GitHub copy matched the local guide byte-for-byte.
S reads public current balances (accepted Riichi deposits included); M reads
the current wall, or Solitaire layout count. These use the existing
announcement shortcut path, with no mutation or private-hand disclosure.

## Scoring foundations

`RiichiScoring` distinguishes yaku from dora, exposed and concealed sets,
winning waits and fu. `Payments` settles ron/tsumo, limits, honba, exhaustive
draws and sanma tsumo loss without the absent player's payment. The selected
fu and kiriage defaults follow the EMA 2025 direction; complete rule-context
validation, liability and round progression remain incomplete. `RiichiState`
and `TableRound` now coordinate declarations, deposits and persistent facts.
The scorer alone must not be treated as a complete Riichi game.

`HongKongScoring` uses an explicit Clear Chapter profile with a three-fan
minimum. `Payments` uses the published eight-fan conversion cap and half-pay
discard settlement. The Power Games preset uses flower/kong replacement from
the remaining wall's back, without a reserved dead wall. This wall convention
is also used by Mahjong Planet; it differs from the reserved-wall setup in
the Mahjong 4 Friends guide. The scoring/bonus conventions remain explicitly
those implemented here; this is not a claim to reproduce either platform's
entire preset. Final special-hand/bonus audit and player documentation remain.

`MCRPatterns` detects candidate fan with their set identities. **Candidates
must not be summed into a score.** `MCRScoring` enumerates winning placements
and selects compatible facts through `MCRPolicy` and `MCRCombination`.
The explicit profile follows the WMO English first edition distributed as
Mahjong_Rule_2013.pdf, with the EMA September 2012 kong clarification.
Independent negative-case and full rule-profile validation remain necessary
before catalog release; online calculators can use different conventions.
Chicken Hand is determined only after final combination; flower points never
establish the eight-point minimum. `Payments.mcr` requires at least eight
non-flower points, but does not establish how those points were earned.

`MCRCombination` is an internal optimizer with explicitly supplied exclusions.
It selects higher-value compatible facts, rejects overlapping repeats of a
compound pattern and cyclic group reuse, and preserves independent repeated
patterns. The optimizer has no built-in exclusion table; `MCRPolicy` supplies
the selected profile. A partial/empty policy is only an optimizer test.
It also accepts scoped exclusions using separate implication metadata, without
mistaking a whole-hand fact for a compound group link. Tests of a subset of
fan establish only that supplied rule's behavior, never the hand's final score.
Other higher fan can still suppress a fact preserved by that one scoped rule.

## Claims and bots

`TileFlow` adds immutable concealed ownership, live-wall draws, discards and
the all-pass transition for three/four seats. It accepts explicitly prepared
hands and a live wall: reserved tiles, initial dealing, bonus replacement and
variant-specific wall policies remain the responsibility of the future rules
adapter. Its observations expose only the viewer's own concealed hand, public
discards and counts. Actions require the current seat, phase and generation.
It transfers chow/pung/kong physical tiles into immutable public sets, then
requires a discard or kong replacement as appropriate. Historical discards
remain separate from the unclaimed river, preserving own-discard furiten.
Flowers are exposed and repeatedly replaced until an ordinary tile is drawn.
The winning draw origin distinguishes direct kong replacement from flower
replacement after a kong, which must not earn MCR's kong-replacement fan.
The wall source is explicit: separate reserve or shared back-wall replacement.

`MCRDeal` deals dealer 14/others 13 with dealer-first flower replacement from
the wall's back. `RiichiDeal` supports four seats and three-seat tile sets, a
14-tile dead wall, up to four replacement draws, live-wall replenishment, and
public dora/private ura indicators. Its normalized physical ordering is defined
in code; it is not a depiction of real table stacks. Sanma currently uses the
existing loss-based payment profile, not the WRC Ron2 full-payment league rules.

`RoundSettlement` joins accepted winning tiles and open/closed set exposure to
Riichi/HK/MCR scoring and zero-sum payments. It derives dora from the wall, flowers
from exposed ownership, and rejects ron on any self-discarded wait or temporary
furiten. MCR derives last-tile, wall exhaustion and direct replacement facts
from accepted tile ownership and draw origin. Flowers remain separate from
the eight-point qualifying threshold. Chicken Hand is determined after
combination leaves no scoring pattern.
An exhausted wall also produces a result: Riichi distributes the ready-hand
penalty; HK and MCR have zero point transfer. Results are immutable and zero-sum.

`TableRound` coordinates draw/discard, all responses, set transfer, temporary
furiten and scored wins, including an exhaustive round. It exposes immutable
legal action plans and a conservative bot planner: win when available, pass
optional calls, otherwise discard using only own tiles and public counts.
Planning never writes events. Riichi additionally
blocks immediate swap-call discards and final-discard non-winning set calls.
Concealed kongs preserve closed-hand scoring and require a replacement before
discarding or claiming self-draw. Added kongs first enter a separate reaction
window. The fourth tile and original pung stay unchanged until all peers
respond; a winning robbery retains the pung and settles the offered tile,
otherwise the set becomes a kong and requires replacement. All three table
scorers receive the accepted robbery fact, without also granting last-discard
or MCR Last Tile bonuses. Native controls and compact events cover this phase.
Riichi declarations select a qualifying discard and remain provisional until
that discard's responses resolve. Ron on the declaration discard voids it;
otherwise the deposit is accepted, the hand locks and scorer facts include
riichi/double riichi, ippatsu and persistent riichi furiten. Calls and kong
declarations interrupt ippatsu; ordinary temporary furiten ends on the
player's own draw or call. Deposits go to the next winner, or remain explicitly
in the ledger after a drawn hand. Public controls show declarations and the pot.

The declaration policy follows WRC 2025's last-live-tile and negative-balance
allowances. Internal initial balances are 30,000 per seat; sanma otherwise
retains its separately documented payment profile. Post-riichi concealed
kongs require the drawn fourth tile, unchanged physical waits and every hand
interpretation, including hypothetical fifth-copy interpretations. The
analysis-only `Hand.virtual_win_forms` never authorizes a physical winning hand.
It does not yet implement per-profile concealed kong robbery exceptions,
liability or match/round/dealer progression. It is not a
claim of full EMA/WRC conformance.

`TableEvents` maps shared native selections to strictly validated compact
session payloads (at most 64 bytes). Payloads never select their actor; the
session adapter derives the seat from the authenticated event account.
`MahjongTableGame` is an internal session adapter for MCR, Hong Kong and
Riichi, including sanma. It replays accepted deals/moves, preserves session and roster
guards, exposes simultaneous pending actors and uses the ordinary bot strategy
and shared executor. Generic history never reveals a drawn tile face.
The deal/replay model follows the existing deterministic card-game convention;
viewer filtering is not cryptographic protection against a modified client.

Tests cover complete MCR/Riichi/sanma incremental and cold replay, shared
archive restoration during a partially answered claim window, and rejecting
old-session input after restore. A native LiveSessions fixture completes one
human/three-bot MCR hand through `GameRoomSessionRunner`, checks persisted
events, final room status and clean feed closure. A separate two-client fixture
keeps a guest's answer valid while other seats respond to the same discard.
These fixtures are not live-server or user acceptance.

`MatchState` adds pure multi-hand bookkeeping: cumulative balances, prevailing
winds, dealer changes, Riichi honba and outstanding deposits. MCR advances
after every hand; the selected HK policy repeats after a dealer win or draw;
Riichi repeats after a dealer win or dealer tenpai draw. Hand-number checks
reject duplicate completion at a repeated dealer boundary. Four winds of MCR
cover sixteen hands. Riichi deposits retained on a draw feed the next hand's
ledger and next winner. The adapter's internal `match_winds` option enables
this model (zero retains single-hand test mode). Between hands every occupied
seat must confirm readiness; ordinary shared bot decisions handle bot votes,
and the first participant's shared automatic action commits the next deal.
The room remains active between hands and only the full match produces the
final game result. UI selections and compact payloads include a hand identity,
so a reused generation in a later hand cannot authorize an old move.
Tests cover a complete four-hand MCR session, native readiness in five
languages, shared executor continuation and archive restore during partial
readiness without applying the previous result again. Tournament seat rotation,
liability and full match-end conventions still need profile audit before a
conformance claim.

`MahjongTablePresentation` uses shared native controls for private owned tiles,
legal discards, claim responses, public sets, flowers, discards and dora. Finished
hands show the winner's tiles, hand value and point changes. Covered ura and
the future wall never enter its specifications. Native EN/PL/CS/ES/RU tests
check arrows versus Enter, stale discard generations and spectator privacy.

`ClaimOffers` derives pung/kong/chow availability from owned physical copies.
Only the next four-seat player can chow. Kong requires an explicit available
replacement draw; winning requires the rules/scoring adapter's positive
validation, not shape alone. These are internal primitives, not a playable
multiplayer adapter or a completed hidden-hand transport.

`ClaimWindow` collects responses for one immutable discard generation. It
requires every peer response before selecting win, pung/kong or chow, and uses
seat order for equal-priority claims. Stale responses and contradictory repeat
responses fail. This is a pure head-bump policy, not a network transport.
Per-profile reaction/call timing still needs integration with accepted history.

`Bot` chooses among supplied legal owned discards using hand distance and
public tile counts. Its observation has no opposing concealed hands or future
wall. Public counts include all exposed tiles; own melds are not counted twice.
The normal shared executor must commit every bot action through `action_for`.
No separate timer, bot scheduler or polling loop is permitted.

## Variant configuration

`MahjongOptions` supplies one shared option form with the variant selector
first. The native editor immediately shows only fields applicable to that
selection and retains the same controls and keyboard focus.

| Variant | Configurable settings | Occupied seats |
| --- | --- | --- |
| Solitaire | Terraces or flat layout | 1 |
| Hong Kong Old Style | One hand, East round, or four wind rounds | 4 |
| Riichi | Four players or three-player sanma; one hand, East, or East/South | 3 or 4 |
| MCR | One hand or four wind rounds (16 hands) | 4 |

Ordinary bot delay is visible only for table variants. Inactive profile fields
are omitted from serialized options; derived `seats` and `match_winds` always
come from the selected profile, never stale input from another variant.
Solitaire has no operative bot delay. Scoring presets, starting points and
other rules without implemented alternatives are fixed, not dummy controls.
Native keyboard tests cover switching through all four variants, field
visibility, declared defaults, unchanged focus, sanma persistence and translated
labels in EN/PL/CS/ES/RU. The registered facade uses this module. Bot management
respects the selected occupied-seat count and excludes Solitaire bot additions
and replacements. Exact roster validation applies again before starting play.

## Current LiveSessions integration

Live Mahjong tables use the shared server-random protocol introduced in 2.0.5.1.
The initial Solitaire layout and every table hand request one native public draw;
`seed_json` renders its entropy as the existing compact JSON event with a bounded
63-bit seed. No client entropy is used on that path. Historical local events and
ordinary saved games keep their original event dialect. The shared executor,
write recovery, participant admission and saved-table preparation remain in use.

Server-generated entropy is public. Mahjong has not opted into protocol-9 private
card pools: ordinary UI hides opponents' tiles, but a modified client can derive
the deal from the seed. This integration does not claim server-private Mahjong
hands or anti-cheat protection. Tournament private-pool support requires a
separate adapter and validation; do not advertise it as implemented.

## Native history budget

Table variants request 32,768 native history entries through the shared game's
`session_history_capacity` hook. Other games retain the default 4,096 entries.
Both new-table creation and saved-game table creation use this declaration.
The store rejects a smaller server grant and closes that session before
attaching the room, rather than accepting a match that cannot retain its log.

An isolated private session on the actual ELTEN server granted 32,768 entries
and was closed after the probe. This requires no server schema change. The
server separately granted 1,536 bytes per entry; archive packing continues to
use actual session limits. The entry budget is finite, not a guarantee of
unlimited dealer repetitions. Native transport tests cover default/requested
budgets and cleanup after a smaller server grant. This is not live Mahjong
match acceptance.

## Test delivery and remaining validation

The local test installer includes all four variants, conditional options,
ordinary bots, full-match transitions, saved-game integration and shared native
surfaces. Rules and player guides are authored in EN/PL/CS/ES/RU; the single
authoritative book is `tools/data/rulebooks/<LANG>/mahjong.json`. Internal
adapters select chapters from its compiled module, avoiding duplicate books.
Translations, native rulebook navigation and actual binary-loaded controls
have been checked. No independent beginner/listening review is implied.

Further profile work includes HK preset audit, advanced Riichi contexts,
concealed-kong robbery exceptions, match-end conventions and independent MCR
pattern/exclusion certification. This test implementation must not be called
complete conformance to every official ruleset. Live acceptance still requires
real human play on separate clients; local broker tests do not establish it.
Keep the existing save/reconnect/private-phase guards. Do not upload or amend
the separate tournament pull request for this work.

## Information shortcuts

The facade uses shared announcement shortcuts: W reads the viewer's current
legal winning value and gain, U their declared melds, Shift+U the other
players' declared melds, R the hand number/winds/current decision, and I the
Riichi indicators, actual dora, own visible-dora count, declarations, deposits,
honba and own furiten status. Personal readouts are unavailable to spectators.
The ordinary pending-tile D and S/M counters remain unchanged. No shortcut
submits a move, changes focus, exposes another concealed hand or binds letters
in editable chat. F1 lists the current shared shortcut definitions.

An incomplete or otherwise ineligible hand has no invented final value.
Pre-win W uses the same settlement rules with `include_ura: false`, includes
the outstanding Riichi pot and explicitly excludes hidden ura-dora. The
default winning/settlement path still includes ura-dora. Public I never
reads hidden indicators or lists hypothetical winning tiles. For a drawn
fourteen-tile hand, discard-based furiten is deferred until after discarding;
temporary and after-Riichi blocks are still reported immediately.

## Event sounds

The catalog facade implements `event_sound_cues` through the shared presenter,
using existing licensed runtime assets: `domino_refill` for dealing,
`domino_take_chip` for ordinary and replacement draws, `domino_move_tile`
for discards and Solitaire pair removal, `play2` for resolved melds and
`reverse` for Solitaire undo. A non-final winning hand uses `win1` and
an exhausted hand uses `draw`; the shared result hook owns final match
victory/loss. Accepted before/after states determine cues, so passing,
unresolved claims, rejected events and repeated snapshots remain silent.
No private tile identity is encoded in audio and no audio loop is added.

## Rule references

- [MCR competition rulebook](https://www.mahjong-ca.org/wp-content/uploads/2019/07/Mahjong_Rule_2013.pdf).
- [EMA kong scoring clarification, September 2012](https://mahjongsoft.com/download/kongscoring.pdf).
- [EMA Riichi 2025](https://mahjong-europe.org/portal/images/docs/Riichi-rules-2025-EN.pdf).
- [WRC Riichi 2025](https://www.worldriichi.org/wrc-rules), particularly wall/dead-wall handling, swap calls and last-tile restrictions. Consulted rules do not imply full preset conformance.
- [Hong Kong Old Style profile and settlement](https://mahjong4friends.com/guides/hong-kong-old-style-mahjong-guide).
- [Hong Kong bonus and basic fan reference](https://mahjongtime.com/hong-kong-mahjong-scoring.html).
- [Hong Kong no-reserved-wall convention](https://mahjong-planet.com/rules/hong-kong/). Its scoring preset differs from the one selected here.

Targeted checks: `ruby test/run.rb test/games/mahjong`.
