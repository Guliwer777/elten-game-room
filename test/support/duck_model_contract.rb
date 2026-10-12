require_relative 'duck_game_adapter'
require_relative 'contract_values'

module GameRoomTest
  module DuckModelContract
    extend Assertions
    module_function

    # The race starts through its host executor, not a player's legal action.
    # Capture that public protocol explicitly instead of an empty simulation.
    def capture
      h = DuckGameAdapterTest::Harness.new(kind: 'dice_duel', count: 3)
      random = Random.new(137)
      original_hex = SecureRandom.method(:hex)
      SecureRandom.define_singleton_method(:hex) { |n = 16| Array.new(n) { random.rand(256).to_s(16).rjust(2, '0') }.join }
      steps = [checkpoint(h)]
      h.open_round
      steps << checkpoint(h)
      h.begin_round
      steps << checkpoint(h)
      3.times do
        round = h.replay.state.fetch(:round)
        seat = GameRoomDuckRacing::ChallengeEngine.current_turn(round.fetch(:engine))
        h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
          'input' => {'kind' => 'roll', 'press_id' => 1}}, actor: h.players.fetch(seat))
        steps << checkpoint(h)
      end
      assert_equal(nil, h.replay.state[:round], 'The three public rolls did not settle')
      h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: h.replay.current_player)
      steps << checkpoint(h)
      {'game' => 'duck_racing', 'seed' => 137, 'steps' => steps, 'events' => h.events}
    ensure
      SecureRandom.define_singleton_method(:hex, original_hex) if original_hex
    end

    def checkpoint(h)
      before = ContractValues.digest([h.session, h.events])
      cached = h.replay
      cold = h.game.build_session_game.replay(h.session, h.events, h.repository)
      assert_equal(ContractValues.canonical(cold), ContractValues.canonical(cached), 'Duck full/incremental mismatch')
      assert_equal(h.events, cached.accepted_events, 'Duck protocol rejected an accepted event')
      unknown = {'id' => 2_000_000_000, 'actor' => 'Unknown', 'action' => '__unknown_contract_event__', 'value' => ''}
      rejected = h.game.replay(h.session, h.events + [unknown], h.repository)
      assert_equal(ContractValues.canonical(cached), ContractValues.canonical(rejected), 'Unknown Duck event changed state')
      assert_equal(before, ContractValues.digest([h.session, h.events]), 'Duck replay changed its inputs')
      {'events' => h.events.length, 'replay' => ContractValues.digest(cached)}
    end
  end
end
