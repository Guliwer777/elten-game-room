# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared/ft2_c08_legacy1594')
input = JSON.parse(File.binread(File.join(directory, 'legacy-input.json')))
context = TournamentPublicServiceSupport::Context.new(directory, input['actor'])
context.now = 201
record = input['record']
path = File.join(directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
expected = {state: :confirmed, reason: :snapshot, current: {'state' => 'ready', 'ready_revision' => 1, 'server_time' => record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1}, receipt: nil, operation_id: nil}
original = File.binread(File.join(directory, 'bound1594.json'))
assert_equal(original, File.binread(path))
result, mutations = c08_observe do
  execution_for(context, record, input['actor']) do |facade|
    select_match(facade, record)
    break facade.current
  end
end
oracle_file('ft2_c08_legacy_read.json', {expected: expected, actual: result, mutations: mutations, exact: original == File.binread(path)})
assert_equal(expected, result, 'RED_FT2A_C08_LEGACY: stary rzeczywisty state z pełnymi zaufanymi referencjami wymaga odczytu bez migracji')
assert_equal([], mutations)
assert_equal(original, File.binread(path))
puts 'GREEN C08: stary prywatny bound1594 odczytany bez migracji i bez zapisu'
