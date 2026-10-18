require_relative '../../support/private_card_games'
require_relative '../../../games/bridge'

game = GameRoomGames::Bridge.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol Dave])
begin
  4.times do |index|
    actor = h.replay('Alice').current_player
    PrivateCardGamesTest.submit(h,runners,actor,{'kind'=>'command','action'=>'call','call'=>index.zero? ? '1N' : 'P'})
  end
  cheated = false
  52.times do
    submitted = false
    replay = h.replay('Alice')
    actor = replay.current_player
    mine = h.replay(actor)
    state = mine.state
    owner = state[:seats][state[:seat_to_play]]
    hand = state[:hands][owner]
    legal = game.legal_actions(mine,actor)
    if !cheated && owner == actor && state[:trick].any?
      bad = hand.find { |card| legal.none? { |action| action['card'] == card } }
      if bad
        receipt = GameRoomPrivateCardLedger.locate(state,actor,bad)
        command = GameRoomPrivateCards.command('play',bad,**receipt.merge(operation:'reveal'))
        h.instance_variable_set(:@session,h.repositories[actor].snapshot_for(h.session).session)
        h.write(actor,[command])
        cheated = true
        submitted = true
      end
    end
    unless submitted
      PrivateCardGamesTest.submit(h,runners,actor,legal.first)
    end
    if h.replay('Alice').state[:phase] == :private_show
      PrivateCardGamesTest.tick(h,runners)
    end
  end
  state = h.replay('Alice').state
  assert(cheated, 'fixture did not produce a revoke')
  assert(state[:private_error] == :invalid_round, 'revoke escaped complete-round audit')
  assert(state[:scores].values.all?(&:zero?) && state[:rubber] == GameRoomGames::BridgeRules.new_rubber, 'invalid round altered rubber')
  assert(state[:deals].empty? && !state[:winner] && !state[:draw], 'invalid result became authoritative')
  assert(h.replay('Alice').history.none? { |entry| [:score,:result].include?(entry.kind) }, 'invalid round announced a score')
  puts 'PASS Bridge forged revoke: accepted native card is audited before any rubber, score or result mutation'
ensure
  runners.each_value(&:close)
end
