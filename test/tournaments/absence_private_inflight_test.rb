require_relative '../support/tournament_presence_native'
require_relative '../support/private_card_games'
require_relative '../support/clock_event_contract'
P = TournamentPresenceNative

[:continuous, :repeated].each do |scenario|
ClockEventContract.with_server_time do |time|
  game = GameRoomGames::Poker.new
  options = game.default_options.merge('variant'=>'holdem')
  TournamentForfeitNative.with_fixture(game: game, users: %w[Alice Bob Carol], options: options) do |f|
    f.start
    h, clock = f.h, [0.0]
    runners = h.users.to_h { |user| [user, P.runner(f, user, clock)] }
    acknowledged = []
    repository = h.repositories.fetch('Bob')
    append = repository.method(:append_events)
    repository.define_singleton_method(:append_events) do |**args|
      append.call(**args).tap { |events| acknowledged.concat(events.to_a) }
    end
    fired, draw_id = false, nil
    native = h.view('Bob')
    original = native.method(:pool_request)
    native.define_singleton_method(:pool_request) do |operation, params, **args|
      if operation == :take && !fired
        fired = true
        draw_id = params.fetch('message_id')
        h.as('Carol') { h.view('Carol').leave }
        step(h, runners.fetch('Alice'))
        assert(P.snapshot(h).session['__frozen'], 'Concurrent host did not commit the pause')
        first_boundary = P.snapshot(h).session['__game_boundary']
        2.times { clock[0] += 15; time.call(1000 + clock[0]); step(h, runners.fetch('Alice')) }
        assert(P.snapshot(h).session['__game_boundary'] != first_boundary, 'The pause did not receive a later checkpoint')
        if scenario == :repeated
          clock[0] = 35; time.call(1035)
          assert(h.join('Carol'))
          step(h, runners.fetch('Alice'))
          assert(!P.snapshot(h).session['__frozen'])
          clock[0] = 40; time.call(1040)
          h.as('Carol') { h.view('Carol').leave }
          step(h, runners.fetch('Alice'))
          assert(P.snapshot(h).session['__frozen'])
        end
        observer = P.observer(f)
        runners[observer] = P.runner(f, observer, clock)
        step(h, runners.fetch(observer), observer)
      end
      original.call(operation, params, **args)
    end
    12.times do
      step(h, runners.fetch('Alice'))
      step(h, runners.fetch('Bob'), 'Bob')
      break if fired
      step(h, runners.fetch('Carol'), 'Carol')
    end
    assert(fired, 'The real private draw boundary was not reached')
    receipts = h.view('Alice').instance_variable_get(:@core).entries.select { |row| row['message_id'] == draw_id }
    assert_equal(1, receipts.size, 'Native draw was not accepted exactly once')
    projected = P.snapshot(h, 'Bob').events.find { |event| event.dig('__server_pool', 'draw_id') == draw_id }
    ack = acknowledged.find { |event| event.dig('__server_pool', 'draw_id') == draw_id }
    assert(ack, 'The real append did not return its private receipt')
    assert_equal(projected, ack, 'The immediate private ACK has a different paused clock from replay')
    assert(h.join('Carol'))
    runners.fetch('Carol').close
    runners['Carol'] = P.runner(f, 'Carol', clock)
    16.times { PrivateCardGamesTest.tick(h, runners) }
    h.users.each do |user|
      snapshot = P.snapshot(h, user)
      accepted_receipt = snapshot.events.find { |event| event.dig('__server_pool', 'draw_id') == draw_id }
      assert(accepted_receipt, 'An accepted private draw disappeared across the tournament pause')
      assert_equal(1, snapshot.events.count { |event| event.dig('__server_pool', 'draw_id') == draw_id })
      assert(!h.replay(user).state[:private_error])
      assert_equal(:betting, h.replay(user).state[:phase], 'Cold returning player did not finish the original private deal')
    end
    PrivateCardGamesTest.assert_private(h)
    # A new account-local repository reconstructs the same accepted receipt.
    runners.fetch('Bob').close
    h.add_client('Bob')
    assert(h.join('Bob'))
    cold = P.snapshot(h, 'Bob')
    assert_equal(1, cold.events.count { |event| event.dig('__server_pool', 'draw_id') == draw_id })
    assert_equal(:betting, h.replay('Bob').state[:phase])
    assert_equal(scenario == :repeated ? 1005 : 1000,
      cold.events.find { |event| event.dig('__server_pool', 'draw_id') == draw_id }['__game_time'],
      'An in-flight receipt advanced the paused logical clock')
  ensure
    runners&.each_value(&:close)
  end
end
end
puts 'PASS native private draw crossing tournament pause: original receipt retained exactly once and round continues'
