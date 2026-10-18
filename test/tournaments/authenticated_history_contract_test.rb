require_relative '../support/assertions'
require_relative '../../lib/tournaments/game_result'
include GameRoomTest::Assertions

history = (1..8).map do |index|
  {'__id' => index * 100, 'id' => index * 100,
    'actor' => index.odd? ? 'Alice' : 'Bob', 'action' => 'place', 'value' => index.to_s}
end
replay = Struct.new(:state, :accepted_events).new({}, [])
valid = ->(events = history) { GameRoomTournaments::GameResult.valid_replay_history?(replay, events) }
original = Marshal.dump(history)

# Every exact ordered subsequence is legitimate: rejection is a game rule
# decision. No receipt, including a rejected one, may be discarded or rewritten.
256.times do |mask|
  replay.accepted_events = history.each_with_index.filter_map { |event, i| event.dup if mask[i] == 1 }
  assert(valid.call, "Valid authenticated subsequence rejected: #{mask}")
  if replay.accepted_events.length > 1
    replay.accepted_events.reverse!
    assert(!valid.call, "Reordered accepted events admitted: #{mask}")
    replay.accepted_events.reverse!
  end
  next if replay.accepted_events.empty?
  replay.accepted_events << replay.accepted_events.last.dup
  assert(!valid.call, 'Duplicated accepted receipt admitted')
end

replay.accepted_events = history.values_at(1, 5).map(&:dup)
invalid_events = [nil, {}, history.reverse, history + [history.last]]
[
  {'id' => 101}, {'__id' => '100', 'id' => '100'}, {'__id' => 0, 'id' => 0},
  {'actor' => nil}, {'actor' => ''}, {'action' => ''}, {'value' => nil}, {'value' => 'x' * 65}
].each do |changes|
  invalid_events << history.map(&:dup).tap { |events| events.first.merge!(changes) }
end
invalid_events.each { |events| assert(!valid.call(events), 'Malformed even rejected receipt admitted') }

missing = history.reject { |event| event['id'] == replay.accepted_events.first['id'] }
assert(!valid.call(missing), 'An accepted receipt absent from raw history was admitted')
replay.accepted_events.first['value'] = 'different'
assert(!valid.call, 'Changed accepted event admitted merely by matching ID')
replay.accepted_events = history.values_at(1, 5).map(&:dup)
replay.state = {private_error: :invalid_round}
assert(!valid.call, 'Private audit failure admitted')
assert_equal(original, Marshal.dump(history), 'Validation mutated the immutable evidence')

puts 'PASS independent authenticated history: 256 accepted subsets, order, duplicates, mismatched ID aliases, malformed rejected receipts, missing/changed accepted payloads and private audit refusal'
