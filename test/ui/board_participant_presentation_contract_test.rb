require_relative '../../lib/game_simulation'
require_relative '../../lib/presentation_replay'
require_relative '../../lib/game_sounds'
require_relative '../../games/four_in_a_row'
require_relative '../../games/mancala'
require_relative '../../games/reversi'
require_relative '../../games/chess'
require_relative '../../games/checkers'

def assert(value, message)
  raise message unless value
end

comparisons = 0
[GameRoomGames::FourInARow, GameRoomGames::Mancala, GameRoomGames::Reversi,
  GameRoomGames::Chess, GameRoomGames::Checkers].each do |type|
  game = type.new
  env = GameRoomSimulation::Environment.new_game(game: game, players: %w[Alice Bob], seed: 725)
  random = Random.new(7)
  8.times do
    break if env.finished?
    actor = env.active_actor
    choices = env.legal_actions(actor)
    assert(!choices.empty?, "#{game.id}: fixture has no legal move")
    assert(env.step(choices.fetch(random.rand(choices.length)), actor: actor) == :ok,
      "#{game.id}: fixture rejected a legal move")
  end
  assert(env.events.length >= 4, "#{game.id}: fixture too short")
  original = env.events.each_with_index.map { |event, index| event.merge('id' => (index + 1) * 10) }
  # Both historical swaps and a human replaced by a named bot are normal
  # participant transitions, not rewritten stored game actions.
  [%w[Carol Bob], %w[Bob Alice], ['bot:1:1:pl20', 'Bob']].each do |roster|
    [25, original.length * 10 + 5].each do |boundary|
      session = env.session.merge('__players' => roster, '__initial_players' => %w[Alice Bob],
        '__seat_changes' => [{'id' => boundary, 'players' => roster}])
      repository = GameRoomSimulation::Repository.new(roster)
      events = original.map do |event|
        next event if event.fetch('id') < boundary
        event.merge('actor' => roster.fetch(%w[Alice Bob].index(event.fetch('actor'))))
      end
      canonical = game.replay(session, events, repository)
      assert(canonical.accepted_events == events, "#{game.id}: fixture lost accepted moves")
      [0, 1, 3].each do |prefix_size|
        presenter = GameRoomPresentationReplay.new(game, repository)
        if prefix_size.positive?
          presenter.remember(session, game.replay(session, events.take(prefix_size), repository))
        end
        original_model = Marshal.dump(canonical)
        full_replay = game.method(:replay)
        full_calls = []
        game.define_singleton_method(:replay) do |*args|
          full_calls << args[1].length
          full_replay.call(*args)
        end
        transitions = presenter.transitions(session, canonical, events.drop(prefix_size))
        game.define_singleton_method(:replay, full_replay)
        expected_calls = prefix_size.zero? ? [0] : []
        events.drop(prefix_size)[0...-1].each_with_index do |event, index|
          expected_calls << prefix_size + index + 1 if event.fetch('id') <= boundary
        end
        assert(full_calls == expected_calls,
          "#{game.id}: repeated complete histories beyond the replacement boundary: #{full_calls.inspect}")
        events.drop(prefix_size).each_with_index do |event, index|
          offset = prefix_size + index
          expected = [game.replay(session, events.take(offset), repository),
            game.replay(session, events.take(offset + 1), repository)]
          actual = transitions.fetch(repository.event_id(event))
          assert(actual.map(&:to_h) == expected.map(&:to_h),
            "#{game.id}: lost intermediate replay at event #{event.fetch('id')}, " \
            "roster #{roster.inspect}, boundary #{boundary}, prefix #{prefix_size}")
          expected_sound = GameRoomSounds.event_cue(game: game, event: event,
            before_replay: expected[0], after_replay: expected[1], repository: repository, viewer: roster.first)
          actual_sound = GameRoomSounds.event_cue(game: game, event: event,
            before_replay: actual[0], after_replay: actual[1], repository: repository, viewer: roster.first)
          assert(actual_sound == expected_sound, "#{game.id}: changed transition sound")
          comparisons += 1
        end
        assert(Marshal.dump(canonical) == original_model, "#{game.id}: mutated canonical replay")
      end
    end
  end
end
puts "Board participant presentation: #{comparisons} intermediate models, histories and sounds passed"
