require_relative '../../support/private_card_games'
require_relative '../../../games/bridge'

game = GameRoomGames::Bridge.new
users = %w[Alice Bob Carol Dave]
h, runners = PrivateCardGamesTest.create(game, users: users)
begin
  4.times do |index|
    actor = h.replay('Alice').current_player
    PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'command', 'action'=>'call', 'call'=>index.zero? ? '1N' : 'P'})
  end
  leader = h.replay('Alice').current_player
  PrivateCardGamesTest.submit(h, runners, leader, game.legal_actions(h.replay(leader), leader).first)
  PrivateCardGamesTest.tick(h, runners)
  state = h.replay('Alice').state
  declarer = state[:current_player]
  dummy = state[:seats][state[:seat_to_play]]
  assert(state[:dummy_visible] && dummy != declarer, 'not testing declarer control of exposed dummy')
  card = game.legal_actions(h.replay(declarer), declarer).first['card']
  before = users.to_h { |user| [user, Marshal.dump(h.replay(user).state)] }
  accepted = h.replay('Alice').accepted_events.size

  # Bypass the user-facing action builder: the immutable reducer must reject
  # a claim by the dummy itself or either defender, even for a public card.
  (users - [declarer]).each do |attacker|
    command = GameRoomPrivateCards.command('play', card, operation:'claim')
    h.instance_variable_set(:@session, h.repositories[attacker].snapshot_for(h.session).session)
    h.write(attacker, [command])
    users.each do |user|
      assert(Marshal.dump(h.replay(user).state) == before[user], "#{attacker} changed #{user}'s dummy projection")
      assert(h.replay(user).accepted_events.size == accepted, "#{attacker} acquired declarer's turn")
    end
  end

  h.add_client('Observer')
  assert(h.join('Observer'), 'observer could not join')
  h.as('Observer') { h.transports['Observer'].set_observer(h.table, true, actor:'Observer') }
  assert_raises(ArgumentError) { h.write('Observer', [GameRoomPrivateCards.command('play', card, operation:'claim')]) }
  # Declarer's own hand must not be used while dummy is on turn.
  own_card = h.replay(declarer).state[:hands][declarer].first
  receipt = GameRoomPrivateCardLedger.locate(h.replay(declarer).state, declarer, own_card)
  h.write(declarer, [GameRoomPrivateCards.command('play', own_card, **receipt.merge(operation:'reveal'))])
  assert(h.replay('Alice').accepted_events.size == accepted, 'declarer played its own card in dummy turn')
  assert(h.replay(declarer).state[:hands][declarer].include?(own_card), 'rejected own card was consumed')
  assert(h.replay(declarer).state[:hands][dummy].include?(card), 'rejected move consumed dummy card')

  PrivateCardGamesTest.submit(h, runners, declarer, game.legal_actions(h.replay(declarer), declarer).first)
  assert(h.replay('Alice').accepted_events.size == accepted + 1, 'legitimate declarer play rejected after attacks')
  assert(!h.replay('Alice').state[:hands][dummy].include?(card), 'legitimate dummy play not consumed')
  PrivateCardGamesTest.assert_private(h)
  puts 'PASS Bridge private authority: forged dummy/defender/observer/own-hand actions rejected, legitimate declarer continues'
ensure
  runners.each_value(&:close)
end
