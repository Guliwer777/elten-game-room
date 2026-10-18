require_relative '../../../games/ninety_nine'
require_relative '../../support/assertions'
include GameRoomTest::Assertions

game = GameRoomGames::NinetyNine.new
repository = Object.new
def repository.event_id(event); event.fetch('id'); end
fields = %i[players options tokens eliminated hands draw_pile discard total direction phase
  current_player pending_player winner]
checks = 0

# The real reducer is the reference, not a second copy of the planning rules.
# Exercise exact/crossed thresholds, elimination, direction and skip effects.
[2, 3, 8].each do |count|
  players = Array.new(count) { |index| "Player#{index}" }
  actor = players.first
  [0, 22, 32, 33, 34, 49, 50, 55, 65, 66, 67, 88, 98, 99].each do |total|
    [0, 1, 2, 9].each do |tokens|
      [-1, 1].each do |direction|
        game.class::RANKS.each do |rank|
          card = "0#{rank}C"
          original = game.send(:initial_state, players, game.default_options)
          rest = game.send(:deck_for, count) - [card]
          original[:hands] = players.to_h { |player| [player, rest.shift(3)] }
          rest.concat(original[:hands][actor])
          original[:hands][actor] = [card]
          original[:discard] = [rest.shift]
          original[:draw_pile] = rest
          original[:tokens] = players.to_h { |player| [player, tokens] }
          original.merge!(phase: :playing, current_player: actor, total: total, direction: direction)
          # A departed/eliminated seat is still skipped in the simulated order.
          if count == 8
            original[:eliminated][players[1]] = true
            original[:tokens][players[1]] = 0
          end
          before = Marshal.dump(original)
          game.send(:card_play_actions, card, total).each do |action|
            actual = NinetyNinePlanning::Transition.play(game, original, actor, action)
            expected = Marshal.load(before)
            event = {'id' => 42, 'actor' => actor, 'value' => action.fetch('card')}
            assert(game.send(:apply_play, expected, event, actor, repository, []), 'reference refused a legal play')
            if expected[:phase] == :awaiting_draw
              assert(game.send(:apply_draw, expected, event, actor, repository, []), 'reference refused replacement draw')
            end
            assert_equal(expected.slice(*fields), actual.slice(*fields),
              "planner differs from game: #{[count, total, tokens, direction, action].inspect}")
            assert_equal(before, Marshal.dump(original), 'planner mutated the source model')
            checks += 1
          end
        end
      end
    end
  end
end
puts "PASS Ninety-nine planner/reducer: #{checks} legal transitions, thresholds, skips, elimination and source isolation"
