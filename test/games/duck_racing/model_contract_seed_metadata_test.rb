require_relative '../../support/duck_model_contract'
include GameRoomTest::Assertions

module DuckSeedMetadataContract
  def checkpoint(harness, legacy: false)
    replay = harness.replay
    before = GameRoomTest::ContractValues.digest(replay)
    inputs = replay.state.fetch(:duck_challenge_events)
    inputs.each do |input|
      assert_equal([:action, :seat, :at, :input, :seed], input.keys)
      assert_equal(nil, input.fetch(:seed))
    end
    projected = reference_projection(replay, legacy: legacy)
    expected = @original_reference.fetch('steps').fetch(@checked_steps)
    assert_equal(expected.fetch('replay'), GameRoomTest::ContractValues.digest(projected), 'A field other than the approved seed metadata changed')
    assert_equal(before, GameRoomTest::ContractValues.digest(replay), 'Comparing the old reference mutated the current replay')
    @observed_trace_counts << inputs.length
    @checked_steps += 1
    if inputs.any?
      [9, :missing].each do |value|
        invalid = Marshal.load(Marshal.dump(replay))
        input = invalid.state.fetch(:duck_challenge_events).first
        value == :missing ? input.delete(:seed) : input[:seed] = value
        rejected = false
        begin
          reference_projection(invalid, legacy: legacy)
        rescue RuntimeError
          rejected = true
        end
        assert(rejected, 'Reference projection silently ignored a missing or nonempty seed')
      end
    end
    super
  end
end

contract = GameRoomTest::DuckModelContract
contract.singleton_class.prepend(DuckSeedMetadataContract)
[[true, 1, [0, 0, 1, 2, 3, 0, 0]], [false, 2, [0, 0, 0, 1, 2, 0, 0]]].each do |legacy, version, trace_counts|
  original = JSON.parse(File.binread(File.join(__dir__, "../../fixtures/contracts/v#{version}/duck_racing.json")))
  contract.instance_variable_set(:@original_reference, original)
  contract.instance_variable_set(:@checked_steps, 0)
  contract.instance_variable_set(:@observed_trace_counts, [])
  actual = contract.capture(legacy: legacy)
  assert_equal(original, actual, 'Original event bytes, ordering or reference checkpoints changed')
  assert_equal(7, contract.instance_variable_get(:@checked_steps))
  assert_equal(trace_counts, contract.instance_variable_get(:@observed_trace_counts))
end
puts 'PASS Duck model references: both unchanged corpora, 14 full replay/RNG hashes, only verified nil seed metadata projected without mutating state'
