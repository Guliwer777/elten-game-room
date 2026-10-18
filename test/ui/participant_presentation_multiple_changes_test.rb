require_relative '../support/assertions'
require_relative '../../lib/game_simulation'
require_relative '../../lib/presentation_replay'
require_relative '../../games/mancala'
require_relative '../../games/reversi'
include GameRoomTest::Assertions

comparisons = 0
[GameRoomGames::Mancala, GameRoomGames::Reversi].each do |type|
  game = type.new
  environment = GameRoomSimulation::Environment.new_game(game: game, players: %w[Alice Bob], seed: 123)
  random = Random.new(12)
  10.times do
    break if environment.finished?
    actor = environment.active_actor
    choices = environment.legal_actions(actor).reject { |choice| choice['action'] == 'pass' }
    assert_equal(:ok, environment.step(choices.fetch(random.rand(choices.size)), actor: actor))
  end
  assert(environment.events.size >= 8, "#{game.id}: fixture ended too early: #{environment.events.size} events")
  changes = [
    {'id' => 25, 'players' => %w[Carol Bob]},
    {'id' => 55, 'players' => %w[Carol Dan]},
    {'id' => 75, 'players' => %w[Dan Carol]}
  ]
  events = environment.events.each_with_index.map do |event, index|
    id = (index + 1) * 10
    roster = changes.reverse.find { |change| change.fetch('id') < id }&.fetch('players') || %w[Alice Bob]
    event.merge('id' => id, 'actor' => roster.fetch(%w[Alice Bob].index(event.fetch('actor'))))
  end
  session = environment.session.merge('__initial_players' => %w[Alice Bob],
    '__players' => %w[Dan Carol], '__seat_changes' => changes)
  repository = GameRoomSimulation::Repository.new(%w[Dan Carol])
  canonical = game.replay(session, events, repository)
  assert_equal(events, canonical.accepted_events)
  untouched = Marshal.dump([session, events, canonical])
  (0...events.size).each do |prefix_size|
    [true, false].each do |same_session|
      presenter = GameRoomPresentationReplay.new(game, repository)
      if prefix_size.positive?
        previous_session = same_session ? session : environment.session
        previous_events = same_session ? events : environment.events.each_with_index.map { |event, i| event.merge('id' => (i + 1) * 10) }
        presenter.remember(previous_session, game.replay(previous_session, previous_events.take(prefix_size), repository))
      end
      result = presenter.transitions(session, canonical, events.drop(prefix_size))
      events.drop(prefix_size).each_with_index do |event, index|
        position = prefix_size + index
        expected = [game.replay(session, events.take(position), repository),
          game.replay(session, events.take(position + 1), repository)]
        assert_equal(expected.map(&:to_h), result.fetch(repository.event_id(event)).map(&:to_h),
          "#{game.id}: wrong historical transition after multiple seat changes, prefix #{prefix_size}")
        comparisons += 1
      end
      assert_equal(untouched, Marshal.dump([session, events, canonical]), 'Presentation changed canonical state')
    end
  end
end
puts "PASS multiple participant changes: #{comparisons} intermediate replays with fresh, warm and obsolete caches"
