require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../../games/taboo'

# A three-card fixture reaches the real native-pool lifecycle quickly; the
# production deck remains 500 phrases and its content validation is unchanged.
class ShortTabooDeck < GameRoomGames::Taboo
  def cards(state); super.first(3); end
  def options_error(*); nil; end
end
game = ShortTabooDeck.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol Dave])
tick = -> { 8.times { PrivateCardGamesTest.tick(h,runners) } }
play = lambda do |user, action, at = nil|
  r = h.replay(user)
  ctx = GameRoomGames::ActionContext.new(table_owner:h.core.owner, now:at || [Time.now.to_i,r.state[:time]].max)
  h.submit(user, {'action'=>action,'token'=>game.token(r.state)}, context:ctx)
end
giver = h.replay('Alice').current_player
play.call(giver,'start')
play.call('Alice','begin',h.replay(giver).state[:deadline])
tick.call
8.times do
  r = h.replay(giver)
  assert(game.card_lines(r.state,giver).size == 6, 'phrase disappeared at a pool boundary')
  play.call(giver,'correct')
  tick.call
end
assert(h.replay(giver).state[:cycle] >= 3, 'did not cross pool boundaries')
play.call('Alice','timeout',h.replay(giver).state[:deadline])
2.times { tick.call }
assert(game.send(:private_review_ready?,h.replay(giver).state), 'old pool phrases not revealed')
play.call('Alice','approve')
assert(h.replay(giver).state[:scores].sum == 8, 'reshuffle changed scoring')
runners.each_value(&:close)
puts 'PASS private Taboo pool recycling: phrases retained across three pools, reveal and scoring'
