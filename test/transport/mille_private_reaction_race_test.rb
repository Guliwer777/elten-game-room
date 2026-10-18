require_relative '../support/mille_private'

opening = %w[go:1 stop:1 25:1 25:2 25:3 25:4 go:2 25:5 25:6 25:7 25:8 25:9
  go:3 right_of_way:1 25:10 50:1 50:2 50:3]
[%w[Carol Bob], %w[Bob Carol]].each do |order|
  h, runners = MillePrivateTest.create(users: %w[Alice Bob Carol], opening: opening)
  %w[Alice Bob Carol].each_with_index do |user, index|
    MillePrivateTest.move(h, runners, user, 'draw')
    MillePrivateTest.move(h, runners, user, 'play', card: "go:#{index + 1}")
  end
  MillePrivateTest.move(h, runners, 'Alice', 'draw')
  MillePrivateTest.move(h, runners, 'Alice', 'play', card: 'stop:1', target: '2')
  plans = %w[Bob Carol].to_h do |user|
    replay = h.replay(user)
    choice = h.game.legal_actions(replay, user).find { |a| a['action'] == (user == 'Bob' ? 'draw' : 'dirty_trick') }
    context = runners[user].send(:context)
    result, plan = h.game.action_for(choice, replay, user, context: context)
    assert(result == :ok, 'could not prepare simultaneous actions')
    [user, plan]
  end
  sequence = h.repositories['Bob'].next_sequence(h.session, h.events('Bob'))
  # Both players acted on the same view. Exercise both server arrival orders.
  order.each { |user| h.write(user, plans[user].events, sequence: sequence) }
  4.times { MillePrivateTest.tick(h, runners) }
  MillePrivateTest.assert_private(h)
  if order.first == 'Carol'
    assert(h.replay('Carol').state[:current_player] == 'Carol', 'safety extra turn lost')
    MillePrivateTest.move(h, runners, 'Carol', 'draw')
    assert(h.replay('Carol').state[:hands]['Carol'].size == 7, 'bonus/normal draws incorrect')
  else
    assert(h.replay('Bob').state[:phase] == :playing, 'confirmed draw stalled')
    assert(h.replay('Bob').state[:hands]['Bob'].size == 7, 'confirmed draw missing')
    assert(h.replay('Carol').state[:hands]['Carol'].include?('right_of_way:1'), 'late safety was consumed')
    MillePrivateTest.move(h, runners, 'Bob', 'discard')
    MillePrivateTest.move(h, runners, 'Carol', 'draw')
    MillePrivateTest.move(h, runners, 'Carol', 'play', card: 'right_of_way:1')
  end
  MillePrivateTest.assert_private(h)
  runners.each_value(&:close)
  puts "PASS private safety versus next player draw, #{order.first} first: no lost card or broken deck"
end
