require_relative '../../../games/catalog'
require_relative '../../support/private_simulation'
require_relative '../../support/model_contract'
include GameRoomTest::Assertions

corpus = JSON.parse(File.read(File.join(__dir__, '../../fixtures/contracts/v1/histories.json'), encoding: 'UTF-8'))
reference = corpus.fetch('cases').find { |item| item.fetch('game') == 'scientific_war' }
current = JSON.parse(File.read(File.join(__dir__, '../../fixtures/contracts/v2/scientific_war.json'), encoding: 'UTF-8'))
without_hashes = lambda do |item|
  item.merge('steps' => item.fetch('steps').map { |step| step.reject { |key, _| key == 'replay' } },
    'final' => item.fetch('final').reject { |key, _| key == 'replay' })
end
assert_equal(without_hashes.call(reference), without_hashes.call(current),
  'Scientific War cleanup must preserve every reference input, action, event, actor, legal-choice digest and RNG sample')
random = Random.new(reference.fetch('seed'))
SecureRandom.define_singleton_method(:hex) { |n = 16| Array.new(n) { random.rand(256).to_s(16).rjust(2, '0') }.join }
env = GameRoomTest::PrivateSimulation.new_game(game: GameRoomGames::ScientificWar.new,
  players: reference.fetch('players'), options: reference.fetch('options'), seed: reference.fetch('seed'))
old_stages = [*reference.fetch('steps'), reference.fetch('final')]
new_stages = [*current.fetch('steps'), current.fetch('final')]
old_stages.each_with_index do |expected, index|
  before = GameRoomTest::ContractValues.digest([env.session, env.events, env.replay])
  commits, receipts = {}, {}
  # Derive receipts only from the immutable historical corpus, never the
  # current model's receipt builder. A commitment alone confirms no cleanup.
  reference.fetch('events').first(expected.fetch('events')).each do |event|
    trick, body = event.fetch('value').split(':', 2)
    actor = event.fetch('actor').downcase
    if event.fetch('action') == 'commit'
      commits[[trick, actor]] = body.unpack1('m0').unpack1('H*')
    elsif event.fetch('action') == 'reveal'
      (receipts["trick:#{trick}"] ||= {})[actor] = commits.fetch([trick, actor])
    end
  end
  assert_equal({session_id: 1, receipts: receipts}, env.replay.state.fetch(:answer_cleanup),
    "Scientific War checkpoint #{index}: unexpected receipt, actor, session or premature cleanup confirmation")
  detached = env.replay.dup
  detached.state = env.replay.state.reject { |key, _| key == :answer_cleanup }
  assert_equal(expected.fetch('replay'), GameRoomTest::ContractValues.digest(detached),
    "Scientific War checkpoint #{index}: historical full replay differs beyond cleanup metadata")
  actual = GameRoomTest::ModelContract.checkpoint(env)
  assert_equal(new_stages.fetch(index).reject { |key, _| key == 'action' }, actual,
    "Scientific War checkpoint #{index}: current full oracle differs")
  assert_equal(expected.reject { |key, _| %w[action replay].include?(key) },
    actual.reject { |key, _| key == 'replay' }, "Scientific War checkpoint #{index}: behavior changed")
  assert_equal(before, GameRoomTest::ContractValues.digest([env.session, env.events, env.replay]),
    'Detached historical comparison changed the actual model')
  assert_equal(:ok, env.step(expected.fetch('action'), actor: expected.fetch('actor'))) if expected.key?('action')
end
assert_equal(reference.fetch('session'), env.session, 'Historical Scientific War session changed')
assert_equal(reference.fetch('events'), env.events, 'Historical Scientific War serialized events changed')
puts 'PASS Scientific War cleanup oracle: exact confirmed receipts, 17 detached historical full hashes, unchanged actions/session/events/actor/legal/RNG'
