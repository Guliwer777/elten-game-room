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
def choose_game(id)
  lambda do |form|
    list = T.field(form, 'Game')
    assert(form.fields.grep(EditBox).empty?, 'Game selection precedes tournament settings')
    list.index = GameRoomGames::CATALOG.ids.index(id)
    list.trigger(:select)
  end
end

snapshot = T.snapshot
calls = []
T.script(lambda do |form|
  actions=form.fields.first
  assert(actions.is_a?(ListBox), 'Tournament actions are the first control')
  actions.index=actions.options.index('Join tournament')
  actions.trigger(:select)
  assert(calls.empty?, 'Blank virtual name must not send registration')
  %w[Alpha Beta Gamma Delta].each do |name|
    T.field(form, 'Virtual player name (local test only)').text = name
    actions.index=actions.options.index('Join tournament')
    actions.trigger(:select)
  end
  assert(calls.map(&:last) == %w[Alpha Beta Gamma Delta], 'Four distinct virtual names join from one preview')
  form.cancel_button.trigger(:press)
end) do
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, load: -> { snapshot }, alert: ->(*) {}),
    clock:-> {150},join_virtual: ->(id, name) { calls << [id, name]; T.record('confirmed') }).wait
end

saved = []
T.script(choose_game('tic_tac_toe'), lambda do |form|
  headers = form.fields.map { |field| field.is_a?(Button) ? field.label : field.respond_to?(:header) ? field.header : nil }
  assert(headers.take(3) == ['Tournament name', 'Tournament format', 'Return matches'], 'Tournament choices follow the separate game settings')
  assert(!headers.include?('Participants and playing windows'), 'No nested tournament details dialog')
  assert(headers.none? { |header| header == 'Tournament rules' }, 'No redundant free-form rules field')
  T.field(form, 'Tournament name').text = 'Simple league'
  T.field(form, 'Return matches').index = 1
  form.accept_button.trigger(:press)
end) do
  GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(_game, options) { options }, publish: ->(**values) { saved << values; {'status' => 'confirmed'} },
    alert: ->(message) { raise message }, clock: -> { Time.local(2026,10,11,15,0).to_i }).wait
end
assert(saved.length == 1, 'Single configuration publishes once')
values = saved.first
assert(values[:draft]['rematch'] && values[:draft]['participant_limit'] == 16 && values[:draft]['windows'].empty?,
  'Publication includes return matches and capacity without compulsory playing hours')
assert(values[:registration_closes_at]==0 && values[:draft]['starts_at']==0, 'Default registration close and start must be manual')
puts 'PASS single configuration and four virtual joins in tournament details'

[nil, {'status' => 'uncertain'}].each do |response|
  calls, notices = [], []
  editor = nil
  T.script(choose_game('tic_tac_toe'), lambda do |form|
    T.field(form, 'Tournament name').text = 'Keep my settings'
    form.accept_button.trigger(:press)
    assert(!editor.instance_variable_get(:@finished), 'Unconfirmed publication must keep the form open')
    assert(T.field(form, 'Tournament name').text == 'Keep my settings', 'Failed publication retains inputs')
    form.accept_button.trigger(:press)
    assert(calls.size == 1, 'Uncertain publication must not be sent twice')
    form.cancel_button.trigger(:press)
  end) do
    editor = GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
      configure: ->(_game, options) { options }, publish: ->(**values) { calls << values; response },
      alert: ->(message) { notices << message }, clock: -> { Time.local(2026,10,11,15,0).to_i })
    editor.wait
  end
  assert(notices.size == 2, 'Repeated unconfirmed submission explains how to recover')
end
puts 'PASS failed publication retains the form and prevents duplicate writes'

saved = []
%w[farkle tic_tac_toe].each do |game_id|
T.script(choose_game(game_id), lambda do |form|
  seats = T.field(form, 'Players per match')
  pairing = T.field(form, 'Multiplayer pairings')
  if game_id == 'farkle'
    assert(seats.options == (2..8).map(&:to_s), 'Match sizes follow the game declaration')
    seats.index = 3
    seats.trigger(:move)
    assert(!form.hidden_controls.include?(pairing), 'Multiplayer pairing is available for five seats')
    pairing.index = 1
  else
    assert(seats.options == ['2'] && seats.index == 0, 'Fixed game offers only its supported match size')
    assert(form.hidden_controls.include?(seats) && form.hidden_controls.include?(pairing), 'Fixed two-seat game skips redundant controls')
  end
  T.field(form, 'Tournament name').text = 'Automatic match size'
  form.accept_button.trigger(:press)
end) do
  GameRoomTournaments::TournamentSetupEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    configure: ->(_game, options) { options }, publish: ->(**values) { saved << values; {'status' => 'confirmed'} },
    alert: ->(message) { raise message }, clock: -> { Time.local(2026,10,11,15,0).to_i }).wait
end
end
assert(saved.map { |row| row[:draft]['players_per_match'] } == [5, 2], 'Publication records each game-derived match size')
puts 'PASS generic game declarations simplify match sizes and multiplayer controls'
