require_relative '../support/mille_private'
require_relative '../../games/spades'

def private_spades(users, options = {})
  marker = {'publication_ref'=>{'author'=>users.first, 'publication_key'=>'spades-life'},
    'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
  game = GameRoomGames::Spades.new
  h = NativeRoomHarness.new(game: game, users: users, tournament: marker,
    options: game.default_options.merge('bot_delay'=>0).merge(options))
  h.start
  runners = users.to_h { |user| [user, runner_for(h, user)] }
  16.times { MillePrivateTest.tick(h, runners) }
  [h, runners]
end

[[4, {'team_size'=>2}], [5, {'no_hell'=>true}], [6, {'team_size'=>3}], [4, {'team_size'=>2, 'suicide'=>true}]].each do |count, options|
  h, runners = private_spades(Array.new(count) { |i| "Player#{i}" }, options)
  assert(h.replay(h.users.first).state[:phase] == :bidding, 'variant stalled before bidding')
  MillePrivateTest.assert_private(h)
  65.times do
    replay = h.replay(h.users.first)
    break if [:round_complete, :finished].include?(replay.state[:phase])
    user = replay.current_player
    mine = h.replay(user)
    action = h.game.legal_actions(mine, user).first
    h.as(user) { assert(runners[user].submit(session: h.session, replay: mine, selection: action, actor: user).first == :ok, 'variant move') }
    MillePrivateTest.assert_private(h)
    h.game.surface_spec(h.replay(user), user)
  end
  assert([:round_complete, :finished].include?(h.replay(h.users.first).state[:phase]), 'variant did not complete')
  runners.each_value(&:close)
end

h, runners = private_spades(%w[Alice Bob Carol])
before = h.replay('Bob').state[:hands]['Bob'].dup
runners['Bob'].close
h.view('Bob').leave
h.add_client('Bob')
assert(h.join('Bob'), 'rejoin failed')
runners['Bob'] = runner_for(h, 'Bob')
MillePrivateTest.tick(h, runners)
assert(h.replay('Bob').state[:hands]['Bob'] == before, 'cold return lost hand')
h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |p| p.user == 'Carol' })
MillePrivateTest.tick(h, runners)
h.instance_variable_set(:@session, h.repositories['Alice'].snapshot_for(h.session).session)
MillePrivateTest.assert_private(h)
foreign = h.replay('Carol').state[:private_draws].find { |_, draw| draw[:player] == 'Bob' }
assert_raises(EltenLink::Error) { h.view('Carol').pool(foreign.last[:pool]).draw(foreign.first) }
assert(h.game.save_game_error(h.replay('Carol')), 'private save allowed')
assert(h.game.participant_replacement_error(h.replay('Carol'), player: 'Bob'), 'private replacement allowed')
3.times do
  user = h.replay('Alice').current_player
  h.submit(user, h.game.legal_actions(h.replay(user), user).first)
end
user = h.replay('Alice').current_player
mine = h.replay(user)
_, plan = h.game.action_for(h.game.legal_actions(mine, user).first, mine, user)
h.instance_variable_set(:@session, h.repositories[user].snapshot_for(h.session).session)
h.broker.automatic_delivery = false
h.view(user).fail_next_push = :after
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write(user, plan.events) }
h.transports[user].reconcile(h.table['__id'])
h.broker.automatic_delivery = true
h.broker.deliver(duplicate: true)
MillePrivateTest.assert_private(h)
assert(h.events(user).count { |event| event['action'] == 'play' } == 1, 'reveal retried as a second play')
runners.each_value(&:close)
puts 'PASS Spades private lifecycle: four variants, cold return, host handover, foreign denial and lost reveal'
