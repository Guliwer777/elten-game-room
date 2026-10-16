# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
_context, _record, _players, _path, healthy = c08_bound_fixture
reference = JSON.parse(healthy)
readback_bytes = JSON.generate(reference['executions'].values.first['target']['readback']).bytesize
core_bytes = JSON.generate(reference['native']).bytesize
assert(core_bytes > readback_bytes + 128, 'Dodatnia kontrola: core oraz args są większe niż sam readback')
class FT2C08CoreLimit < TournamentFixedTeamNativeService
  def initialize(limit); @limit = limit; end
  def limits; super.merge('core_bytes' => @limit); end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + '-empty')
actor = record['evidence']['plan']['matches'].first['players'].first['username']
result, mutations = c08_observe do
  execution_for(context, record, actor, native_provider: FT2C08CoreLimit.new(readback_bytes + 128)) do |facade|
    select_match(facade, record)
    break facade.request_match
  end
end
state_path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
actual = {result: result, mutations: mutations, exists: File.exist?(state_path)}
expected = {result: {state: :blocked, reason: :native_limits, operation_id: nil, binding: nil}, mutations: [], exists: false}
oracle_file('ft2_c08_native_aggregate.json', {expected: expected, actual: actual, readback_bytes: readback_bytes, core_bytes: core_bytes, limit: readback_bytes + 128})
assert_equal(expected, actual, 'RED_FT2A_C08_NATIVE_AGGREGATE: limit całego core nie jest limitem samego readback')
puts 'GREEN C08: lower core obejmuje wszystkie utrwalane natywne dane przed zapisem wykonania'
