require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_preview'
require_relative '../../lib/tournaments/tournament_setup_editor'
require_relative '../../lib/tournaments/local_workspace'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
Form.prepend(TournamentPublicUI::Script)
T = TournamentPublicUI
def assert(value, message); raise message unless value; end

snapshot = T.snapshot
calls = []
T.script(lambda do |form|
  T.button(form, 'Join tournament').trigger(:press)
  assert(calls.empty?, 'Blank virtual name must not send registration')
  %w[Alpha Beta Gamma Delta].each do |name|
    T.field(form, 'Virtual player name (local test only)').text = name
    T.button(form, 'Join tournament').trigger(:press)
  end
  assert(calls.map(&:last) == %w[Alpha Beta Gamma Delta], 'Four distinct virtual names join from one preview')
  form.cancel_button.trigger(:press)
end) do
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, load: -> { snapshot }, alert: ->(*) {}),
    join_virtual: ->(id, name) { calls << [id, name]; T.record('confirmed') }).wait
end

saved = []
T.script(lambda do |form|
  headers = form.fields.map { |field| field.is_a?(Button) ? field.label : field.respond_to?(:header) ? field.header : nil }
  assert(headers.take(5) == ['Game', 'Game settings', 'Tournament name', 'Tournament format', 'Return matches'], 'Tab order starts with game and tournament choices')
  assert(!headers.include?('Participants and playing windows'), 'No nested tournament details dialog')
  assert(headers.index('Tournament starts: Start: year') < headers.index('Tournament rules') &&
    headers.index('Tournament rules') < headers.index('Registration opens: Start: year'), 'Playing time, rules and registration are in requested Tab order')
  T.field(form, 'Tournament name').text = 'Simple league'
  T.field(form, 'Game').index = GameRoomGames::CATALOG.ids.index('tic_tac_toe') + 1
  assert(T.field(form, 'Return matches').index == 2, 'Return matches enabled by default')
  form.accept_button.trigger(:press)
end) do
  GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(*) { nil }, publish: ->(**values) { saved << values; {'status' => 'confirmed'} },
    alert: ->(message) { raise message }, clock: -> { Time.local(2026,10,11,15,0).to_i }).wait
end
assert(saved.length == 1, 'Single configuration publishes once')
values = saved.first
assert(values[:draft]['rematch'] && values[:draft]['participant_limit'] == 16 && values[:draft]['windows'].size == 1,
  'Publication includes return matches, capacity and playing window')
assert(values[:registration_closes_at] > values[:registration_opens_at], 'Registration dates configured before publication')
puts 'PASS single configuration and four virtual joins in tournament details'

[nil, {'status' => 'uncertain'}].each do |response|
  calls, notices = [], []
  editor = nil
  T.script(lambda do |form|
    T.field(form, 'Tournament name').text = 'Keep my settings'
    T.field(form, 'Game').index = GameRoomGames::CATALOG.ids.index('tic_tac_toe') + 1
    form.accept_button.trigger(:press)
    assert(!editor.instance_variable_get(:@finished), 'Unconfirmed publication must keep the form open')
    assert(T.field(form, 'Tournament name').text == 'Keep my settings', 'Failed publication retains inputs')
    form.accept_button.trigger(:press)
    assert(calls.size == 1, 'Uncertain publication must not be sent twice')
    form.cancel_button.trigger(:press)
  end) do
    editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
      configure: ->(*) { nil }, publish: ->(**values) { calls << values; response },
      alert: ->(message) { notices << message }, clock: -> { Time.local(2026,10,11,15,0).to_i })
    editor.wait
  end
  assert(notices.size == 2, 'Repeated unconfirmed submission explains how to recover')
end
puts 'PASS failed publication retains the form and prevents duplicate writes'

saved = []
T.script(lambda do |form|
  game = T.field(form, 'Game')
  seats = T.field(form, 'Players per match')
  pairing = T.field(form, 'Multiplayer pairings')
  game.index = GameRoomGames::CATALOG.ids.index('farkle') + 1
  game.trigger(:move)
  assert(seats.options == (2..8).map(&:to_s), 'Match sizes follow the game declaration')
  seats.index = 3
  seats.trigger(:move)
  assert(!form.hidden_controls.include?(pairing), 'Multiplayer pairing is available for five seats')
  game.index = GameRoomGames::CATALOG.ids.index('tic_tac_toe') + 1
  game.trigger(:move)
  assert(seats.options == ['2'] && seats.index == 0, 'Changing game removes incompatible match sizes')
  assert(form.hidden_controls.include?(seats) && form.hidden_controls.include?(pairing), 'Fixed two-seat game skips redundant controls')
  T.field(form, 'Tournament name').text = 'Automatic match size'
  form.accept_button.trigger(:press)
end) do
  GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(*) { nil }, publish: ->(**values) { saved << values; {'status' => 'confirmed'} },
    alert: ->(message) { raise message }, clock: -> { Time.local(2026,10,11,15,0).to_i }).wait
end
assert(saved.first[:draft]['players_per_match'] == 2, 'Publication records the game-derived match size')
puts 'PASS generic game declarations simplify match sizes and multiplayer controls'
