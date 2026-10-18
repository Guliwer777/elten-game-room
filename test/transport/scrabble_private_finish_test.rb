require_relative '../support/private_card_games'
require_relative '../../games/scrabble'

# Boundary fixture: a 14-tile bag, not a claim of a full normal-length match.
# Apply to the runner's newly constructed models as well, in this test process.
GameRoomGames::Scrabble.prepend(Module.new do
  def tiles(state); super.first(14); end
end)
game = GameRoomGames::Scrabble.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob],
  options:game.normalize_options('content_language_id'=>'en'), random_values:Array.new(16,8))
assert(h.replay('Alice').state[:bag].empty?, 'fixture bag not empty')
expected = h.users.to_h do |user|
  state = h.replay(user).state
  [user, -state[:racks][user].sum { |id| game.tiles(state)[id][:points] }]
end
6.times do |index|
  PrivateCardGamesTest.tick(h,runners)
  before = h.replay('Alice')
  actor = before.current_player
  assert(actor, "pass #{index} missing actor: #{before.state.inspect}; events #{h.events('Alice').inspect}")
  PrivateCardGamesTest.submit(h,runners,actor,{'action'=>'pass'})
end
20.times { PrivateCardGamesTest.tick(h,runners) }
h.users.each do |user|
  result = h.replay(user)
  assert(result.finished?, 'private final scoring did not finish')
  assert(result.state[:scores] == expected, 'private rack scores wrong')
  assert(result.state[:racks].equal?(result.state[:hands]), 'final rack alias lost')
  assert(result.accepted_events.size == h.events(user).size, 'final receipt rejected')
end
PrivateCardGamesTest.assert_private(h)
runners.each_value(&:close)
puts 'PASS private Scrabble depleted-bag finish, disclosure and leftover scoring'
