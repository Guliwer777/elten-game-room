require_relative '../support/session_runner'
require_relative '../support/elten_array_shuffle'
%w[spades tysiac three_five_eight ninety_nine uno makao poker].each do |name|
  require_relative "../../games/#{name}"
end

class ForbiddenDealSource
  def roll(**); raise 'Local entropy used for a server deal'; end
end

games = [GameRoomGames::Spades, GameRoomGames::Tysiac, GameRoomGames::ThreeFiveEight,
  GameRoomGames::NinetyNine, GameRoomGames::Uno, GameRoomGames::Makao, GameRoomGames::Poker]
games.each do |klass|
  [0, 30].each do |thinking_time|
    game = klass.new
    users = %w[Alice Bob Carol]
    options = game.default_options.merge('thinking_time'=>thinking_time)
    h = NativeRoomHarness.new(game: game, users: users, options: options)
    h.start
    ctx = GameRoomGames::ActionContext.new(random_source: ForbiddenDealSource.new, server_random: true,
      table_owner: 'Alice', now: 1000)
    h.view('Alice').next_random_values = Array.new(16, 2)
    selection = game.automatic_action(h.replay('Alice'), 'Alice', context: ctx)
    assert(selection, "#{game.id}: missing automatic deal")
    h.submit('Alice', selection, context: ctx)
    assert(h.replay('Alice').accepted_events.size == 1, "#{game.id}/#{thinking_time}: deal rejected")
    h.assert_converged("#{game.id}/#{thinking_time}", expected_count: 1)
    assert(h.view('Alice').calls[:random] == 1, 'extra random request')
    event = h.events('Alice').first
    legacy = event.reject { |key, _| key == '__server_random' }
    before = GameRoomTest::ReplaySnapshot.capture(h.replay('Alice')).except(:accepted_events)
    after = GameRoomTest::ReplaySnapshot.capture(game.replay(h.session, [legacy], h.repositories['Alice'])).except(:accepted_events)
    assert(before == after, "#{game.id}: legacy semantics changed")
    # A server draw with an arbitrary template may not choose the dealer.
    bad = Marshal.load(Marshal.dump(event))
    bad['__server_random']['recipe']['template'].sub!('{dealer}', '2')
    assert(game.replay(h.session, [bad], h.repositories['Alice']).accepted_events.empty?, "#{game.id}: chosen dealer accepted")
    runner = runner_for(h)
    step(h, runner)
    assert(h.events('Alice').count { |row| row['action'] == 'deal' } == 1, "#{game.id}: the runner repeated the deal")
    runner.close
  end
end
puts 'PASS server card deals: seven games, clocks, legacy dialects, native shuffle API and no chosen dealer'
