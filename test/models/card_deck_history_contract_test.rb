require_relative '../../games/base'
require_relative '../../lib/card_deck_history'
require_relative '../support/assertions'
include GameRoomTest::Assertions

game = Class.new { include GameRoomCardDeckHistory }.new
entry = ->(id, key) do
  GameRoomGames::HistoryEntry.new(key: key, text: key, event_id: id, actor: 'Player', kind: :draw)
end
history = [entry.call(11, 'old'), entry.call(12, 'draw'), entry.call(12, 'exchange'), entry.call(13, 'later')]
game.send(:record_deck_reshuffle, history, 1, 2, 12)
assert_equal(%w[old reshuffle:12 draw exchange later], history.map(&:key), 'recycle reordered accepted events')
assert_equal(:reshuffle, history[1].kind, 'recycle missing history presentation type')
assert_equal('', history[1].actor, 'public deck recycle incorrectly attributed to a participant')
before = Marshal.dump(history)
[[1, 2, 12], [2, 2, 14], [3, 2, 15]].each do |from, to, id|
  game.send(:record_deck_reshuffle, history, from, to, id)
  assert_equal(before, Marshal.dump(history), 'duplicate/no-op recycle changed public history')
end
game.send(:record_deck_reshuffle, history, 2, 3, 16)
assert_equal('reshuffle:16', history.last.key, 'new accepted recycle without sibling history lost')
puts 'PASS deck history: accepted increase only, first same-event placement, public actor and duplicate suppression'
