require_relative '../../support/private_card_games'
require_relative '../../../games/bridge'

game = GameRoomGames::Bridge.new
users = %w[Alice Bob Carol Dave]
h, runners = PrivateCardGamesTest.create(game, users: users, options: {'variant'=>'duplicate', 'boards'=>4})
begin
  originals = users.to_h { |user| [user, h.replay(user).state[:hands][user].dup] }
  # A cold reader must recover its account-owned receipt, not redraw.
  before_takes = h.core.entries.count { |entry| entry.dig('pool', 'operation') == 'take' }
  runners['Bob'].close
  h.view('Bob').leave
  h.add_client('Bob')
  assert(h.join('Bob'), 'cold rejoin failed')
  runners['Bob'] = runner_for(h, 'Bob')
  PrivateCardGamesTest.tick(h, runners)
  assert(h.replay('Bob').state[:hands]['Bob'] == originals['Bob'], 'cold reader lost its hand')
  assert(h.core.entries.count { |entry| entry.dig('pool', 'operation') == 'take' } == before_takes, 'return drew again')
  4.times do |index|
    actor = h.replay('Alice').current_player
    PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'command','action'=>'call','call'=>index.zero? ? '1N' : 'P'})
  end
  leader = h.replay('Alice').current_player
  PrivateCardGamesTest.submit(h, runners, leader, game.legal_actions(h.replay(leader), leader).first)
  assert(h.replay('Alice').state[:phase] == :private_show, 'not awaiting dummy')
  # An observer can become host while the hand owner still owes disclosure.
  h.add_client('Watcher')
  assert(h.join('Watcher'), 'observer could not join')
  h.as('Watcher') { h.transports['Watcher'].set_observer(h.table, true, actor:'Watcher') }
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |part| part.user == 'Watcher' })
  runners['Watcher'] = runner_for(h, 'Watcher')
  step(h, runners['Watcher'], 'Watcher')
  watcher = h.replay('Watcher')
  assert(!watcher.state[:dummy_visible], 'new host received unproved dummy')
  assert(watcher.state[:hands].values.flatten.all? { |card| GameRoomPrivateCardLedger.hidden?(card) || watcher.state[:private_public].include?(card) },
    'new host gained private cards')
  dummy = watcher.state[:seats][GameRoomGames::BridgeRules.partner_of(watcher.state[:contract].declarer)]
  mine = h.replay(dummy)
  selection = game.automatic_action(mine, dummy, context: GameRoomGames::ActionContext.new(table_owner:'Watcher'))
  status, plan = game.action_for(selection, mine, dummy, context: GameRoomGames::ActionContext.new(table_owner:'Watcher'))
  assert(status == :ok && plan.events.first.action == 'private_show', 'dummy owner cannot reveal')
  h.instance_variable_set(:@session, h.repositories[dummy].snapshot_for(h.session).session)
  h.broker.automatic_delivery = false
  h.view(dummy).fail_next_push = :after
  assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write(dummy, plan.events) }
  h.transports[dummy].reconcile(h.table['__id'])
  h.broker.automatic_delivery = true
  h.broker.deliver(duplicate: true)
  PrivateCardGamesTest.tick(h, runners)
  assert(h.events(dummy).count { |event| event['action'] == 'private_show' } == 1, 'lost ACK duplicated disclosure')
  assert(h.replay('Watcher').state[:dummy_visible], 'new host stayed waiting after disclosure')
  assert(h.replay(dummy).history.count { |entry| entry.kind == :dummy } == 1, 'dummy repeated in history')
  actor = h.replay('Alice').current_player
  action = game.legal_actions(h.replay(actor), actor).first
  PrivateCardGamesTest.submit(h, runners, actor, action)
  PrivateCardGamesTest.assert_private(h)
  assert(game.save_game_error(h.replay(actor)), 'private save allowed')
  assert(game.participant_replacement_error(h.replay(actor), player:dummy), 'private replacement allowed')
  puts 'PASS Bridge private lifecycle: cold return, spectator host, dummy lost ACK, continued play, no save/replacement'
ensure
  runners.each_value(&:close)
end

# A passed-out comparison needs the authenticated initial hands before a
# score exists. All owners disclose once; no arbitrary seed hands are used.
%w[imp mp].each do |scoring|
  h, runners = PrivateCardGamesTest.create(game, users:users,
    options:{'variant'=>'duplicate','boards'=>4,'scoring'=>scoring})
  begin
    4.times do
      actor = h.replay('Alice').current_player
      PrivateCardGamesTest.submit(h,runners,actor,{'kind'=>'command','action'=>'call','call'=>'P'})
    end
    state = h.replay('Alice').state
    assert(state[:phase] == :private_show && state[:deals].empty? && state[:scores].values.all?(&:zero?), 'unverified pass-out score')
    users.each do |user|
      step(h, runners[user], user)
    end
    state = h.replay('Alice').state
    assert(state[:phase] == :round_complete && state[:deals].size == 1, "pass-out stalled: #{state[:phase]}")
    assert(state[:initial_hands].flatten.uniq.size == 52, 'pass-out audit omitted hands')
    score = h.replay('Alice').history.select { |entry| entry.kind == :score }
    assert(score.size == 1 && score.first.text.include?('Score'), 'pass-out comparison silent')
    PrivateCardGamesTest.assert_private(h)
    puts "PASS Bridge private #{scoring}: passed-out comparison waits for all receipts and is announced once"
  ensure
    runners.each_value(&:close)
  end
end
