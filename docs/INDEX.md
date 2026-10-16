# Documentation

The [tournament administrator handoff](TOURNAMENT_ADMIN_HANDOFF.md) describes
the clean official client, package contents and server deployment boundaries.

Technical and contributor documentation is maintained in English, in the
existing files. Player guides and game rules remain multilingual; their
translations must be kept up to date together.

## For players

- [Power Games — user guide](../content/readme/EN.md): getting started,
  tables, invitations, the widget, settings, saved games and key shortcuts.
  The [Polish guide](../README.md) and the other translations in
  [content/readme/](../content/readme/) remain available.

## Planned fixes

- [New Game Room fixes plan](NEXT_FIXES_PLAN.md):
  implementation scope and explicitly marked questions still to be settled.
- [Duck Racing implementation plan](DUCK_RACING_PLAN.md):
  implementation in progress, starting with Peaceful Pond; agreed rules and
  required local and live-game verification.

## Maintenance

- [Architecture](ARCHITECTURE.md): data flow, layers and their responsibilities.
- [Host API](HOST_API.md): the final ELTEN 3.0.4 contract.
- [Building](BUILDING.md): dependencies, tests, generators and staging.
- [Adding a game](ADDING_A_GAME.md): integrating the model, UI, content and bots.
- [Snapshot ownership](SNAPSHOT_OWNERSHIP.md) and [benchmarks](BENCHMARKS.md).
- [Tools](TOOLS.md), [testing](TESTING.md)
  and [translations](TRANSLATIONS.md): current commands and directory layout.
- [Bot training](BOT_TRAINING.md): evaluating strategies and using the Spades tools.

## Feature contracts

- [Forms and help](UI.md), [card hands](CARD_HAND.md)
  and the [audio tutorial](AUDIO_TUTORIAL.md).
- [Background execution and presentation](BACKGROUND_GAME_EXECUTION.md).
- [Realtime](REALTIME.md) and [Audio Ball](AUDIO_BALL.md).
- [Private answers and saved games](PRIVATE_STATE.md).
- [Teams, roles and focus](TEAMS_ROLES_AND_FOCUS.md).
- [Interface languages](INTERFACE_LANGUAGES.md).
- [Statistics](STATISTICS.md) and their [schema fragment](STATISTICS_TABLES.json).
- [Question creator](QUIZ_CONTRIBUTIONS.md): private account drafts and
  proposals delivered through messages with a TXT/JSON attachment.
- [Monopoly board sources and limitations](MONOPOLY_REGIONAL_BOARDS.md).

## Maintained content

The [quiz editorial guidelines](QUIZ_EDITORIAL.md) are mandatory when creating,
importing, extending or translating question sets. They cover natural language,
sources, three plausible wrong answers, duplicates and a review of every item,
with guidance for Polish, English, Czech, Spanish, Russian and future languages.

The [game rulebook editorial guidelines](RULES_EDITORIAL.md) are mandatory
when writing, importing, revising or translating rules. They provide an
adaptable outline, worked editorial examples, professional references and a
first-turn walkthrough, and teach essential controls beside the actions they
perform. Remove irrelevant topics without compressing needed explanations
into formulas. A separate shortcut reference helps players recall keys;
general application help and
implementation details remain outside the rules.

[tools/data/rulebooks/](../tools/data/rulebooks/) contains rulebook sources for
the `tools/compile-rulebooks.rb` compiler. The game loads generated Ruby from
`games/generated/rulebooks/` and MO translations; JSON stays outside the package.
Polish source text is refreshed from PO; the procedure is described in
[docs/TRANSLATIONS.md](TRANSLATIONS.md).

The application's changelog has a single source:
[game_room_changelog.rb](../lib/game_room_changelog.rb), translated through PO/MO
and displayed in What's new. We do not maintain separate Markdown copies of
release notes.

The [readable quiz question lists](quiz-questions/) are exports from `content/`
for editorial review. The game reads Ruby packs in `content/`; TXT files are
not its data source. Each TXT corresponds to a set and contains a sequential
number, question, choices A–D and the correct answer, without technical IDs.
Numbering starts at 1 in each set; answer order is fixed and may differ from
the order during a game. The “Wiedźmin — książki” (The Witcher — books) set
replaces all previous Witcher sets; it excludes games and screen adaptations.
To report an error, provide the set name and question text. Edit the data in
`content/`, then run:

```console
ruby tools/export-quiz-text.rb
ruby tools/export-quiz-text.rb --check
```

Exports use UTF-8 and preserve each set's provenance and licensing information;
they are not included in the installer. `--check` verifies that they are up to
date without writing files.

Keep test reports, audits, measurements and one-off experiment reports in the
ignored `tmp/` directory or outside the repository. Git preserves the change
history; update current contracts in the documents listed above.

The [ordinary tournament team trial](TOURNAMENT_ORDINARY_TEAM_TRIAL.md) documents
native team bindings and shared result validation in the owned developer app,
including the boundaries that still require server support.

The [sporting phase trial and daily dates](TOURNAMENT_PHASE_TRIAL.md) describes
immutable shared round progression and local civil-day schedule editing.

The [manual forfeit trial](TOURNAMENT_FORFEIT_TRIAL.md) documents organizer
decisions for unstarted matches and the boundary for abandoned native games.

The [saved tournament match trial](TOURNAMENT_SAVED_MATCH_TRIAL.md) describes
authenticated continuations across saved-game restoration into a new table.
