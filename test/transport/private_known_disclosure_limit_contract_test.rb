require_relative '../support/private_card_games'
require_relative '../../games/poker'

# A real native reveal may be ordered before the game asks for showdown.
# Reuse that immutable evidence without another native reveal or an oversized
# ordinary action when the unchanged Poker reducer later needs the hand.
h, runners = PrivateCardGamesTest.create(GameRoomGames::Poker.new,
  users: %w[Alice Bob Carol], options: {'variant'=>'draw', 'jacks_or_better'=>false})
begin
  state = h.replay('Alice').state
  cards = state[:hands].fetch('Alice')
  assert(cards.size == 5, 'not five-card draw')
  receipts = cards.map { |card| GameRoomPrivateCardLedger.locate(state, 'Alice', card) }
  assert(receipts.map { |receipt| receipt[:draw_id] }.uniq.one?, 'opening hand is not one receipt')
  first = receipts.first
  h.write('Alice', [GameRoomPrivateCards.command('private_show', 'showdown', operation:'reveal',
    pool_id:first[:pool_id], draw_id:first[:draw_id], values:receipts.map { |receipt| receipt[:value] })])
  assert(h.replay('Alice').state[:hands]['Alice'] == cards, 'premature disclosure changed the hand')

  80.times do
    rep = h.replay('Alice')
    break if rep.state[:phase] == :private_show
    if rep.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h, runners)
    else
      actor = rep.current_player
      choice = h.game.legal_actions(h.replay(actor), actor).find do |item|
        %w[check call].include?(item['action']) || (item['action'] == 'exchange' && item['cards'] == '[]')
      end
      assert(choice, 'no ordinary betting/exchange choice')
      PrivateCardGamesTest.submit(h, runners, actor, choice)
    end
  end
  rep = h.replay('Alice')
  assert(rep.state[:phase] == :private_show, 'showdown not reached')
  command = GameRoomPrivateCardDisclosure.command(rep.state, 'Alice')
  assert(command.pool_request == {'operation'=>'claim'}, 'known proof incorrectly reveals again')
  assert(command.value.length <= GameRoomEventProtocol::MAX_VALUE_LENGTH,
    "known disclosure exceeds the wire limit: #{command.value.length} > #{GameRoomEventProtocol::MAX_VALUE_LENGTH}")
  count = h.view('Alice').calls[:reveal]
  80.times do
    break if h.replay('Alice').state[:phase] == :hand_complete
    PrivateCardGamesTest.tick(h, runners)
  end
  assert(h.replay('Alice').state[:phase] == :hand_complete, 'known disclosure did not finish showdown')
  assert(h.view('Alice').calls[:reveal] == count, 'already public cards were natively revealed again')
  PrivateCardGamesTest.assert_private(h)
ensure
  runners.each_value(&:close)
end

# Native takes may contain 100 values. Every ordinary claim stays bounded,
# makes progress and is single-use, including values with three digits.
draw_id = '12345678-1234-1234-1234-123456789012'
state = {players:%w[Alice Bob], phase: :playing, current_player:'Alice', private_viewer:'Alice',
  private_public:[], private_values:{draw_id=>(1..100).to_a},
  private_known:{draw_id=>(1..100).to_a},
  private_draws:{draw_id=>{pool:'pool', player:'Alice', count:100, used:[]}},
  private_pools:{'pool'=>{cards:(1..100).map { |n| "card-#{n}" }}},
  hands:{'Alice'=>(1..100).map { |n| "card-#{n}" }}}
GameRoomPrivateCardDisclosure.prepare(state, ['Alice'], purpose:'action')
count = 0
until GameRoomPrivateCardDisclosure.complete?(state)
  command = GameRoomPrivateCardDisclosure.command(state, 'Alice')
  GameRoomEventProtocol.validate_commands!([command])
  event = {'action'=>'private_show', 'value'=>command.value}
  assert(!GameRoomPrivateCardDisclosure.apply(state, event, 'Bob'), 'foreign known proof accepted')
  assert(GameRoomPrivateCardDisclosure.apply(state, event, 'Alice'), 'bounded known claim was rejected')
  assert(!GameRoomPrivateCardDisclosure.apply(state, event, 'Alice'), 'same known claim spent twice')
  count += 1
  assert(count <= 100, 'bounded disclosure made no progress')
end
assert(state[:private_public].size == 100 && count > 1, 'large receipt was not completely disclosed')
puts 'PASS native premature disclosure, bounded known-proof claims and ordinary Poker showdown'
