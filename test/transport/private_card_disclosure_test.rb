require_relative '../support/private_card_games'
require_relative '../../games/poker'

h, runners = PrivateCardGamesTest.create(GameRoomGames::Poker.new, users: %w[Alice Bob Carol])
100.times do
  rep = h.replay('Alice')
  break if rep.state[:phase] == :private_show
  if rep.state[:phase].to_s.start_with?('private_')
    PrivateCardGamesTest.tick(h, runners)
  else
    actor = rep.current_player
    action = h.game.legal_actions(h.replay(actor), actor).find { |item| %w[check call].include?(item['action']) }
    PrivateCardGamesTest.submit(h, runners, actor, action)
  end
end
rep = h.replay('Alice')
assert(rep.state[:phase] == :private_show, 'no showdown to test')
command = GameRoomPrivateCardDisclosure.command(rep.state, 'Alice')
assert(command.pool_request['values'].size == 2, 'not a batched reveal')
assert(GameRoomPrivateCards.valid_request?(command.pool_request), 'invalid batch request')
assert(!GameRoomPrivateCards.valid_request?(command.pool_request.merge('values'=>[1,1])), 'duplicate values accepted')
assert(!GameRoomPrivateCards.valid_request?(command.pool_request.merge('values'=>[])), 'empty reveal accepted')
assert(!GameRoomPrivateCards.valid_request?(command.pool_request.merge('values'=>[0])), 'zero accepted')
snapshot = h.repositories['Alice'].snapshot_for(h.session)
h.instance_variable_set(:@session, snapshot.session)
h.broker.automatic_delivery = false
h.view('Alice').fail_next_push = :after
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', [command]) }
h.transports['Alice'].reconcile(h.table['__id'])
h.broker.automatic_delivery = true
h.broker.deliver(duplicate: true)
rep = h.replay('Bob')
shows = h.events('Bob').select { |event| event['action'] == 'private_show' }
assert(shows.size == 1 && shows.first['__server_pool']['values'].size == 2, 'uncertain batch duplicated')
assert(rep.state[:hands]['Alice'].all? { |card| rep.state[:private_public].include?(card) }, 'batch not materialized')
state = Marshal.load(Marshal.dump(rep.state))
before = Marshal.dump(state)
assert(!GameRoomPrivateCardDisclosure.apply(state, shows.first, 'Bob'), 'foreign disclosure accepted')
assert(Marshal.dump(state) == before, 'foreign disclosure mutated state')
assert(!GameRoomPrivateCardDisclosure.apply(state, shows.first, 'Alice'), 'spent receipt accepted twice')
assert(Marshal.dump(state) == before, 'replayed disclosure mutated state')
10.times { PrivateCardGamesTest.tick(h, runners) unless [:hand_complete, :finished].include?(h.replay('Alice').state[:phase]) }
assert(h.replay('Alice').state[:phase] == :hand_complete, 'showdown did not complete')
PrivateCardGamesTest.assert_private(h)
runners.each_value(&:close)
puts 'PASS shared batched disclosure, native provenance, uncertain acknowledgement and replay rejection'
