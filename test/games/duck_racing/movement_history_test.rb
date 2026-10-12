require_relative '../../support/ui'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_surfaces'
require_relative '../../../lib/game_history_view'

include DuckGameAdapterTest

h = Harness.new
h.start(seed: h.seed_for('helix'))
card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'helix' }
h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id, 'target' => 0}}, actor: 'Alice')
h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
replay = h.replay
before = DuckGameAdapterTest.semantic(replay.state)
entries = h.game.history_entries_for_display(replay, 'Alice', surface_state: {})
rolled = entries.rindex { |entry| entry.kind == :rolled }
assert(rolled, 'The fixture did not record its roll')
assert_equal(:moved, entries[rolled + 1].kind)
assert(entries[rolled + 1].text.start_with?('Alice lands on '))

repository = TableActivityRepository.new(server_tables: {})
merged = repository.merged_history_entries(game_entries: entries,
  game_events: replay.accepted_events, activity_entries: [], game_name: ->(_id) { 'Duck Racing' })
assert_equal(entries.map(&:text), merged.map(&:text), 'History merged distinct notices from one action')
view = GameRoomHistory::View.new(header: 'History')
view.replace_entries(merged.map(&:text))
assert_equal(entries.map(&:text).join("\n"), view.text.delete("\r"))
assert(!view.text.include?("\n\n"), 'History inserted an empty line')
entries.each_index do |index|
  view.entry_index = index
  assert_equal(index, view.entry_index, 'The history cursor skipped a notice')
end
assert_equal(before, DuckGameAdapterTest.semantic(replay.state), 'Displaying history mutated the game')

puts 'PASS Duck movement through accepted replay, display projection, activity merge and one-line-per-notice history control'
