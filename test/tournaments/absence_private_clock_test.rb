require_relative '../support/tournament_presence_native'
require_relative '../support/private_card_games'
require_relative '../support/clock_event_contract'
P = TournamentPresenceNative

ClockEventContract.with_server_time do |time|
  game = GameRoomGames::Poker.new
  options = game.default_options.merge('variant'=>'holdem', 'thinking_time'=>30)
  TournamentForfeitNative.with_fixture(game: game, options: options) do |f|
    f.start
    h, clock = f.h, [0.0]
    runners = h.users.to_h do |user|
      runner = P.runner(f, user, clock)
      runner.instance_variable_set(:@clock, ClockEventContract.clock)
      [user, runner]
    end
    16.times { PrivateCardGamesTest.tick(h, runners) }
    PrivateCardGamesTest.assert_private(h)
    before = h.users.to_h { |user| [user, h.replay(user).state[:hands][user].dup] }
    deadline = h.replay('Alice').state[:turn_deadline]
    accepted = h.events('Alice')
    time.call(1001)
    h.as('Bob') { h.view('Bob').leave }
    step(h, runners['Alice'])
    time.call(1091)
    clock[0] += 90
    step(h, runners['Alice'])
    current = P.snapshot(h)
    assert_equal(1001, ClockEventContract.clock.now(current.session), 'Tournament pause consumed private turn time')
    assert_equal(deadline, h.replay('Alice').state[:turn_deadline])
    assert_equal(accepted, h.events('Alice'), 'Absence changed the private hand or forced a fold')
    assert(h.join('Bob'))
    runners.fetch('Bob').close
    runners['Bob'] = P.runner(f, 'Bob', clock)
    runners.fetch('Bob').instance_variable_set(:@clock, ClockEventContract.clock)
    PrivateCardGamesTest.tick(h, runners)
    assert_equal(1001, ClockEventContract.clock.now(P.snapshot(h).session))
    h.users.each { |user| assert_equal(before[user], h.replay(user).state[:hands][user], 'Return redrew private cards') }
    PrivateCardGamesTest.assert_private(h)
    actor = h.replay('Alice').current_player
    choice = game.legal_actions(h.replay(actor), actor).find { |item| %w[call check].include?(item['action']) }
    assert(choice)
    PrivateCardGamesTest.submit(h, runners, actor, choice)
    assert(h.events('Alice').size > accepted.size, 'Private game did not continue after the return')
  ensure
    runners&.each_value(&:close)
  end
end
puts 'PASS actual private poker: absence pauses logical deadline, retains hands/proofs, return and next ordinary move'
