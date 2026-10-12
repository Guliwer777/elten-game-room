# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_event_presenter'
include DuckGameAdapterTest

h = Harness.new
h.start
game = h.game
players = %w[Alice Bob]
repository = h.repository

# All squares retain their numbered landing. Flavour is local to the duck
# that arrived, including in history; an observer hears the public effects.
(1..30).each do |square|
  history = []
  movement = LOGIC::Board::Move.new(square - 1, square, 1, false)
  game.send(:append_notices, history, [[:moved, 0, movement], [:feathers, 0, 1]], 77, players)
  assert_equal([:moved, :scenery, :feathers], history.map(&:kind))
  assert_equal('Alice', history[1].actor)
  assert(history[1].text.end_with?('.') && !history[1].text.include?("\n"))
  replay = h.replay
  replay.history = history
  original = Marshal.dump(replay)
  ['Alice', 'alice', 'Bob', 'Observer'].each do |viewer|
    expected = viewer.downcase == 'alice' ? history : [history[0], history[2]]
    assert_equal(expected.map(&:text), game.history_entries_for_display(replay, viewer).map(&:text))
    assert_equal(expected.map(&:text), game.describe_event({'id' => 77}, repository, replay, viewer))
    assert_equal(original, Marshal.dump(replay), 'Local flavour filtering changed the shared replay')
  end
  # Replacement does not rewrite who actually heard the old landing.
  replay.players = %w[Replacement Bob]
  assert_equal([:moved, :feathers], game.history_entries_for_display(replay, 'Replacement').map(&:kind))
end

# Public speech uses the same viewer filter and plays each accepted action
# once. Cold replay and the presentation-prefix cache keep the same scenery.
speeches = Hash.new { |hash, key| hash[key] = [] }
clock = [0.0]
presenters = (players + ['Observer']).to_h do |viewer|
  [viewer, GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
    program: -> { nil }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
    clock: -> { clock.first }, covered: -> { false }, speech: ->(text) { speeches[viewer] << text },
    trace: ->(*) {}, history_changed: ->(*) {}, session_changed: -> {})]
end
presenters.each_value { |presenter| presenter.process_new_events(h.replay, session: h.session) }
h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
presenters.each_value { |presenter| presenter.process_new_events(h.replay, session: h.session) }
scenery = h.replay.history.select { |entry| entry.kind == :scenery }
assert(!scenery.empty?)
assert(scenery.none? { |entry| speeches['Alice'].include?(entry.text) }, 'Landing overtook the roll pause')
1_000.times do
  break if presenters.values.none?(&:event_presentation_busy?)
  clock[0] += 0.1
  presenters.each_value { |presenter| presenter.event_presentation.advance }
end
assert(presenters.values.none?(&:event_presentation_busy?), 'Landing presentation stalled')
scenery.each do |entry|
  assert_equal(1, speeches['Alice'].count(entry.text))
  assert(!speeches['Bob'].include?(entry.text) && !speeches['Observer'].include?(entry.text))
end
snapshot = JSON.generate(speeches)
presenters.each_value { |presenter| presenter.process_new_events(h.replay, session: h.session) }
assert_equal(snapshot, JSON.generate(speeches), 'Refresh repeated a landing description')
cold = GameRoomGames::DuckRacing.new(resources: h.resources).replay(h.session, h.events, h.repository)
assert_equal(cold.history.map(&:to_h), h.replay.history.map(&:to_h))

# Expiration is a notice, not a second roll or a new random draw. Modifiers
# still last exactly the requested number of race rolls.
state = LOGIC::Race.start(player_count: 2, laps: 3, seed: 13, enabled_challenges: ['dice_duel'])
LOGIC::Dice.change!(state[:racers][0], sides: 10, rolls: 1)
state[:random] = Random.new(0) # first d10 roll is 6: a question square
expected_roll = Random.new(0).rand(10) + 1
assert(LOGIC::Race.new(state).apply(seat: 0, revision: 0, action: {kind: :roll}))
assert_equal([[:rolled, 0, expected_roll], [:die_changed, 0, 6, 0]], state[:notices].first(2))
assert_equal([6, 0], state[:racers][0].values_at(:die_sides, :die_rolls))
history = []
game.send(:append_notices, history, state[:notices], 78, players)
assert_equal('Alice returns to the ordinary six-sided die.', history[1].text)

# Frozen and ordinary skipped turns must not offer an actionable turn or
# play its ding. A genuine next turn keeps the common presenter's behaviour.
[[0, 1], [1, 0], [2, 2]].each do |frozen, skipped|
  before = Harness.new.tap(&:start).replay
  after = Marshal.load(Marshal.dump(before))
  race = after.state[:race]
  race[:turn] = 1
  racer = race[:racers][1]
  racer[:frozen_turns], racer[:skip_turns] = frozen, skipped
  after.current_player = 'Bob'
  assert_equal(nil, game.required_decision_key(after, 'Bob'))
  assert_equal(nil, game.turn_announcement(after, 'Bob'))
  assert_equal(nil, game.turn_transition_history_entry(before, after, event_id: 79))
  expected = frozen.positive? ? 'Bob is frozen and skips this turn.' : 'Bob skips this turn.'
  assert_equal(expected, game.turn_text(after))
  assert(LOGIC::Race.new(race).apply(seat: 1, revision: race[:revision], action: {kind: :skip}))
  history = []
  game.send(:append_notices, history, race[:notices], 79, players)
  assert_equal(1, history.count { |entry| entry.kind == :skipped })
  assert_equal(expected, history.first.text)
  assert_equal(frozen == 1, history.any? { |entry| entry.kind == :thawed })
  after.current_player = 'Alice'
  assert(game.required_decision_key(after, 'Alice'))
  assert_equal('It is your turn.', game.turn_announcement(after, 'Alice'))
  assert(game.turn_transition_history_entry(before.dup.tap { |replay| replay.current_player = 'Bob' }, after, event_id: 80))
end

# Actual accepted blackjack draws keep their rank and total, then explicitly
# announce going over 21. No optimistic or repeated local draw is invented.
b = Harness.new(kind: 'blackjack')
b.open_round
b.begin_round
busts = 0
60.times do
  round = b.replay.state[:round]
  break unless round
  seat = LOGIC::ChallengeEngine.current_turn(round[:engine])
  press = round[:engine][:last_press].fetch(seat) + 1
  count = b.replay.history.length
  b.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
    'input' => {'kind' => 'hit', 'press_id' => press}}, actor: players.fetch(seat))
  entry = b.replay.history.drop(count).find { |item| item.kind == :challenge_draw }
  total = entry.text.match(/Total: (\d+)\./)[1].to_i
  if total > 21
    assert_equal("#{players.fetch(seat)} goes over 21.", entry.text.split("\n").last)
    busts += 1
  else
    assert(!entry.text.include?("\n"))
  end
end
assert(busts.positive?, 'No accepted bust was exercised')
assert_equal(nil, b.replay.state[:round])

puts 'PASS all 30 local square descriptions, viewer/history isolation, accepted speech and repeat refresh, die expiry, skipped/frozen turns and accepted blackjack busts'
