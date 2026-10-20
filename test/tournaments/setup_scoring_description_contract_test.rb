require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
require_relative '../../lib/tournaments/standings'
require_relative '../support/assertions'
include GameRoomTest::Assertions

GameRoomLocalization.boot(settings: {'interface_language'=>'en', 'known_languages'=>['en']})
Form.prepend(TournamentPublicUI::Script)
ui = TournamentPublicUI
expected = 'Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents.'

[['three_five_eight', {}], ['tic_tac_toe', {}], ['spades', {'team_size'=>2}]].each do |game_id, options|
  published = []
  editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(game, values) { game.normalize_options(values.merge(options)) }, clock: -> { 1000 },
    alert: ->(message) { raise message }, publish: ->(**values) { published << values; {'status'=>'confirmed'} })
  ui.script(->(form) {
    game = ui.field(form, 'Game')
    game.index = GameRoomGames::CATALOG.ids.index(game_id)
    game.trigger(:select)
  }, ->(form) {
    ui.field(form, 'Tournament name').text = 'Scoring description'
    form.accept_button.trigger(:press)
  }) { editor.wait }
  assert_equal(1, published.size)
  assert_equal(expected, published.first.fetch(:rules), "#{game_id}: newly published rules contradict multiplayer scoring")
end

# Editing an existing publication must preserve the organizer's own wording.
publication = ui.publication(913, game: 'three_five_eight')
original = Marshal.load(Marshal.dump(publication))
published = []
editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
  publication: publication, configure: ->(_game, options) { options }, clock: -> { 100 },
  alert: ->(message) { raise message }, publish: ->(**values) { published << values; {'status'=>'confirmed'} })
ui.script(->(form) { form.accept_button.trigger(:press) }) { editor.wait }
assert_equal(publication.fetch('rules'), published.first.fetch(:rules))
assert_equal(original, publication)

# Back reopens the selected game's options, without publishing or losing the
# tournament's text. Notes use the existing rules column, not a new schema.
published = []
configured = []
notes = "Bring your own tea.\nContact the organizer before the final."
editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
  configure: ->(game, values) { configured << [game.id, Marshal.load(Marshal.dump(values))]; values }, clock: -> { 1000 },
  alert: ->(message) { raise message }, publish: ->(**values) { published << values; {'status'=>'confirmed'} })
ui.script(->(form) {
  game = ui.field(form, 'Game')
  game.index = GameRoomGames::CATALOG.ids.index('tic_tac_toe')
  game.trigger(:select)
}, ->(form) {
  ui.field(form, 'Tournament name').text = 'Back preserves this name'
  ui.field(form, "Organizer's notes (optional)").text = notes
  form.fields.grep(Button).find { |field| field.label == 'Back' }.trigger(:press)
  assert_equal([], published)
  assert_equal('Back preserves this name', ui.field(form, 'Tournament name').text)
  assert_equal(notes, ui.field(form, "Organizer's notes (optional)").text)
  assert_equal(2, configured.size)
  assert_equal(configured.first, configured.last)
  form.accept_button.trigger(:press)
}) { editor.wait }
assert_equal(notes, published.fetch(0).fetch(:rules))

# Automatic text is a language-neutral default on the wire, not a copy of the
# creator's interface translation. Legacy defaults are not editable author notes.
%w[en pl cs es ru].each do |language|
  GameRoomLocalization.boot(settings: {'interface_language'=>language, 'known_languages'=>[]})
  localized = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
  published = []
  editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(_game, values) { values }, clock: -> { 1000 }, alert: ->(message) { raise message },
    publish: ->(**values) { published << values; {'status'=>'confirmed'} })
  ui.script(->(form) {
    game=ui.field(form,localized.call('Game'))
    game.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe')
    game.trigger(:select)
  }, ->(form) {
    ui.field(form,localized.call('Tournament name')).set_text('Canonical default')
    form.accept_button.trigger(:press)
  }) { editor.wait }
  assert_equal(expected,published.fetch(0).fetch(:rules),"#{language}: new publication stored translated automatic rules")
  legacy=ui.publication(914).merge('rules'=>localized.call(expected))
  editor=GameRoomTournaments::TournamentSetupEditor.new(program:Object.new,registry:GameRoomGames::CATALOG,
    publication:legacy,configure:->(_game,values){values},clock:->{100},alert:->(message){raise message},
    publish:->(**values){published<<values;{'status'=>'confirmed'}})
  ui.script(->(form) {
    assert_equal('',ui.field(form,localized.call("Organizer's notes (optional)")).text,
      "#{language}: editing exposed automatic rules as organizer-authored notes")
    form.accept_button.trigger(:press)
  }) { editor.wait }
  assert_equal(expected,published.fetch(1).fetch(:rules))
end

# The wording agrees with the real arithmetic, not a replacement test formula.
standings = GameRoomTournaments::Standings
table = standings.calculate(units: %w[a b c], points: standings::MATCH_POINTS,
  results: [{'id'=>'three', 'participants'=>%w[a b c], 'winners'=>['a'], 'scores'=>{'a'=>9, 'b'=>5, 'c'=>1}}])
assert_equal({'a'=>4, 'b'=>2, 'c'=>0}, table.to_h { |row| [row['unit'], row['points']] })
table = standings.calculate(units: %w[pair_a pair_b], points: standings::MATCH_POINTS,
  results: [{'id'=>'teams', 'participants'=>%w[pair_a pair_b], 'winners'=>[], 'scores'=>nil}])
assert_equal([1, 1], table.map { |row| row['points'] })
puts 'PASS default tournament rules match per-opponent scoring for two, three and team entries; existing author rules remain unchanged'
