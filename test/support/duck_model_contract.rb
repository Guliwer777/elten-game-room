require_relative 'duck_game_adapter'
require_relative 'contract_values'

module GameRoomTest
  module DuckModelContract
    extend Assertions
    module_function

    # The race starts through its host executor, not a player's legal action.
    # Capture that public protocol explicitly instead of an empty simulation.
    def capture(legacy: false)
      # Both immutable corpora predate the one-second default. Their options
      # remain explicit historical inputs, just like their recorded actions.
      h = DuckGameAdapterTest::Harness.new(kind: 'dice_duel', count: 3, options: {'bot_delay' => 0})
      random = Random.new(137)
      original_hex = SecureRandom.method(:hex)
      SecureRandom.define_singleton_method(:hex) { |n = 16| Array.new(n) { random.rand(256).to_s(16).rjust(2, '0') }.join }
      steps = [checkpoint(h, legacy: legacy)]
      h.start(seed: h.seed_for('super_challenge'), legacy: true) if legacy
      h.open_round
      steps << checkpoint(h, legacy: legacy)
      h.begin_round
      steps << checkpoint(h, legacy: legacy)
      3.times do
        round = h.replay.state.fetch(:round)
        seat = GameRoomDuckRacing::ChallengeEngine.current_turn(round.fetch(:engine))
        h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
          'input' => {'kind' => 'roll', 'press_id' => 1}}, actor: h.players.fetch(seat))
        steps << checkpoint(h, legacy: legacy)
      end
      assert_equal(nil, h.replay.state[:round], 'The three public rolls did not settle')
      h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: h.replay.current_player)
      steps << checkpoint(h, legacy: legacy)
      {'game' => 'duck_racing', 'seed' => 137, 'steps' => steps, 'events' => h.events}
    ensure
      SecureRandom.define_singleton_method(:hex, original_hex) if original_hex
    end

    def checkpoint(h, legacy: false)
      before = ContractValues.digest([h.session, h.events])
      cached = h.replay
      cold = h.game.build_session_game.replay(h.session, h.events, h.repository)
      assert_equal(ContractValues.canonical(cold), ContractValues.canonical(cached), 'Duck full/incremental mismatch')
      assert_equal(h.events, cached.accepted_events, 'Duck protocol rejected an accepted event')
      unknown = {'id' => 2_000_000_000, 'actor' => 'Unknown', 'action' => '__unknown_contract_event__', 'value' => ''}
      rejected = h.game.replay(h.session, h.events + [unknown], h.repository)
      assert_equal(ContractValues.canonical(cached), ContractValues.canonical(rejected), 'Unknown Duck event changed state')
      assert_equal(before, ContractValues.digest([h.session, h.events]), 'Duck replay changed its inputs')
      comparable = reference_projection(cached, legacy: legacy)
      {'events' => h.events.length, 'replay' => ContractValues.digest(comparable)}
    end

    # Server-random support annotates public challenge inputs with their seed.
    # Both recorded corpora predate that source of randomness: each new field
    # must exist and be nil. Verify it, then compare every original Replay
    # field (including all RNG state) against the unchanged reference bytes.
    def reference_projection(replay, legacy: false)
      copy = legacy ? legacy_projection(replay) : Marshal.load(Marshal.dump(replay))
      copy.state.fetch(:duck_challenge_events).each do |event|
        assert(event.key?(:seed), 'Duck public input seed metadata is missing')
        assert_equal(nil, event.delete(:seed), 'Historical Duck input unexpectedly received a new random seed')
      end
      copy
    end

    # Protocol 2 adds bookkeeping even when reading a protocol 1 game. Verify
    # those additions explicitly, then compare every old field against v1.
    # The v2 corpus retains these protocol-2 fields without removing them.
    def legacy_projection(replay)
      copy = Marshal.load(Marshal.dump(replay))
      state = copy.state
      assert_equal([], state.delete(:result_closures))
      if state[:race]
        assert_equal(nil, state.delete(:challenge_flow))
        assert_equal(state[:session_id], state.delete(:protocol_session))
      end
      assert_equal(nil, state[:round].delete(:results)) if state[:round]
      # Build 249 also attached a final-lap flag to movement notices. This
      # corpus stays on lap one; no final-lap announcement may be introduced.
      notices = (state[:notices] + Array(state.dig(:race, :notices))).uniq(&:object_id)
      notices.select { |notice| notice.first == :moved }.each do |notice|
        assert_equal(5, notice.length)
        assert_equal(false, notice.pop)
      end
      copy
    end
  end
end
