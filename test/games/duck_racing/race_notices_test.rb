# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'

include DuckGameAdapterTest

game = Harness.new.game
players = %w[Alice Bob Carol Dave Eve Frank Grace Heidi]
history = []
append = lambda do |notices, names = players|
  before = Marshal.dump(notices)
  first = history.length
  game.send(:append_notices, history, notices, 100 + first, names)
  assert_equal(before, Marshal.dump(notices), 'Presentation changed the model notices')
  history.drop(first).reject { |entry| entry.kind == :scenery }
end
move = ->(from, to, laps = 4) { LOGIC::Board.advance(from, by: to - from, laps: laps) }

append.call([[:started]])
ordinary = append.call([[:rolled, 0, 4], [:moved, 0, move.call(0, 4)], [:feathers, 0, 1]])
assert_equal(['Alice rolls 4.', 'Alice lands on square 5. Diving board.', 'Alice receives 1 feather.'], ordinary.map(&:text))
assert_equal([:rolled, :moved, :feathers], ordinary.map(&:kind))
assert_equal([0, 1], [ordinary[1].field, ordinary[1].value])

# All three notices belong to the same accepted action. The shared history
# merger must retain each one in order, rather than combine by event ID.
activity_repository = TableActivityRepository.new(server_tables: {})
merged = activity_repository.merged_history_entries(game_entries: ordinary,
  game_events: [{'__id' => ordinary.first.event_id, '__stack_sequence' => 7}],
  activity_entries: [], game_name: ->(_id) { 'Duck Racing' })
assert_equal(ordinary.map(&:text), merged.map(&:text))
assert_equal([:game, :game, :game], merged.map(&:category))
assert(merged.all? { |entry| entry.text.end_with?('.') && !entry.text.include?("\n") })

forward = append.call([[:moved, 0, move.call(4, 32)]])
assert_equal('Alice lands on square 3. Front pond. Begins lap 2.', forward.first.text)
same_lap = append.call([[:moved, 0, move.call(32, 35)]])
assert_equal('Alice lands on square 6. South bank.', same_lap.first.text)
backward = append.call([[:moved, 0, move.call(35, 29)]])
assert_equal('Alice lands on square 30. Finish line. Returns to lap 1.', backward.first.text)

# A sequence of landing effects is presented in order, with one notice per
# actual boundary crossing, not again for every later move in that lap.
chain = append.call([[:rolled, 0, 5], [:moved, 0, move.call(29, 34)],
  [:moved, 0, move.call(34, 39)], [:feathers, 0, -2],
  [:moved, 0, move.call(39, 27)], [:moved, 0, move.call(27, 28)]])
assert_equal(1, chain.count { |entry| entry.text.include?('Begins lap 2.') })
assert_equal(1, chain.count { |entry| entry.text.include?('Returns to lap 1.') })
assert_equal('Alice loses 2 feathers.', chain.find { |entry| entry.kind == :feathers }.text)
assert_equal([:rolled, :moved, :moved, :feathers, :moved, :moved], chain.map(&:kind))

jump = append.call([[:moved, 0, move.call(28, 94)]])
assert_equal('Alice lands on square 5. Diving board. Begins lap 4.', jump.first.text)
jump_back = append.call([[:moved, 0, move.call(94, 2)]])
assert_equal('Alice lands on square 3. Front pond. Returns to lap 1.', jump_back.first.text)

# Places are independent even with indistinguishable names. A replacement
# inherits the place's progress and must not trigger another lap announcement.
same_names = Array.new(8, 'Player')
(1..7).each do |seat|
  result = append.call([[:moved, seat, move.call(0, 31)]], same_names)
  assert_equal('Player lands on square 2. Forest edge. Begins lap 2.', result.first.text)
end
replacement = append.call([[:moved, 7, move.call(31, 34)]], players.first(7) + ['Replacement'])
assert_equal('Replacement lands on square 5. Diving board.', replacement.first.text)

exact_finish = append.call([[:moved, 0, move.call(2, 90, 3)], [:won, 0]])
assert_equal(['Alice reaches the finish.'], exact_finish.map(&:text))
overshoot = append.call([[:moved, 1, move.call(31, 94, 3)], [:won, 1]])
assert_equal(['Bob reaches the finish.'], overshoot.map(&:text))
assert(exact_finish.none? { |entry| entry.text.include?('lap 4') })
append.call([[:started]])
assert_equal('Alice lands on square 3. Front pond.', append.call([[:moved, 0, move.call(0, 2)]]).first.text)

class DuckNoticeHistory < Array
  attr_reader :visits

  def reverse_each
    return enum_for(__method__) unless block_given?

    @visits = 0
    super { |entry| @visits += 1; yield entry }
  end
end
long_history = DuckNoticeHistory.new(Array.new(10_000) do |index|
  GameRoomGames::HistoryEntry.new(kind: :drew_cards, text: 'Old message', event_id: index)
end)
long_history << GameRoomGames::HistoryEntry.new(kind: :moved, field: 0, value: 2, text: 'Old position')
game.send(:append_notices, long_history, [[:moved, 0, move.call(31, 34)]], 10_001, players)
assert_equal(1, long_history.visits, 'Movement searched past its previous place entry')
assert_equal('Alice lands on square 5. Diving board.', long_history[-2].text)
assert_equal(:scenery, long_history.last.kind)

# The normal adapter stores only action commands. Both a cold reconstruction
# and the authenticated-prefix cache regenerate exactly the same metadata and
# speech; a server archive restored to a new session does the same.
h = Harness.new
h.start(seed: h.seed_for('helix'))
card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'helix' }
h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id, 'target' => 0}}, actor: 'Alice')
h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
current = h.replay
assert(current.history.any? { |entry| entry.kind == :moved })
saved_state = DuckGameAdapterTest.semantic(current.state)
cold = GameRoomGames::DuckRacing.new(resources: h.resources).replay(h.session, h.events, h.repository)
assert_equal(cold.history.map(&:to_h), current.history.map(&:to_h))
assert_equal(current.history.map(&:to_h), h.replay.history.map(&:to_h))
assert_equal(saved_state, DuckGameAdapterTest.semantic(h.replay.state))
saves, row = h.archive
restored, = h.restore_native(saves, row)
restored_history = restored.replay('Alice').history
assert_equal(current.history.map { |entry| [entry.kind, entry.text, entry.field, entry.value] },
  restored_history.map { |entry| [entry.kind, entry.text, entry.field, entry.value] })

# C and S remain complete manual inspections, including current lap/total,
# card counts, feathers and the named square. Reading them is model-pure.
current.state[:race][:racers][0][:progress] = 32
before = Marshal.dump(current.state)
manual = game.racer_text(current, 0)
assert(manual.include?('lap 2 of 3, square 3 (Front pond), feathers:'))
assert(manual.include?('cards:'))
shortcuts = game.custom_game_shortcuts(current, 'Alice')
assert_equal(manual, shortcuts.find { |shortcut| shortcut.key == 'c' }.message)
assert(shortcuts.find { |shortcut| shortcut.key == 's' }.message.include?(manual))
assert_equal(before, Marshal.dump(current.state), 'Manual inspection mutated its input')
assert_equal(saved_state, DuckGameAdapterTest.semantic(h.replay.state), 'Manual inspection mutated the cached replay')

puts 'PASS concise race movement: ordinary rolls, forward/backward laps, chained effects, 8 places, replacement, finish, bounded history lookup, cached/cold/archive replay and full C/S'
