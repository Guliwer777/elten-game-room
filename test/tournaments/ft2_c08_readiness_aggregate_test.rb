# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
actor = record['evidence']['plan']['matches'].first['players'].first['username']
projections = []; at_claim = nil
trace = TracePoint.new(:return, :call) do |e|
  if e.event == :return && e.defined_class == T::Publication::Data.singleton_class && e.method_id == :copy
    value = e.return_value
    if value.is_a?(Hash) && value.keys.sort == %w[busy executions identity native readiness records version]
      projections << JSON.parse(JSON.generate(value))
    end
  elsif e.event == :call && e.defined_class == T::ReadinessJournal && e.method_id == :claim
    at_claim = JSON.parse(JSON.generate(projections))
  end
end
result = nil
execution_for(context, record, actor) do |facade|
  select_match(facade, record)
  trace.enable(target_thread: nil)
  begin
    result = facade.declare(availability: 'ready', expected_revision: 0)
  ensure
    trace.disable
  end
end
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(path))
oracle_file('ft2_c08_readiness_aggregate.json', {at_claim: at_claim, actual: state, result: result, expected_record: record})
assert_equal(:confirmed, result[:state])
assert(at_claim && at_claim.any? { |p| p['records'].values == [record] && p['readiness'].size == 1 },
  'RED_FT2A_C08_READY_AGGREGATE: przed claim musi przejść serializer całego stanu po dodaniu rekordu i readiness')
assert_equal([result[:receipt]], state['readiness'], 'Nie zapisano fikcyjnego receipt z projekcji')
puts 'GREEN C08: pełny agregat readiness/record przed claim, trwały wyłącznie rzeczywisty receipt'
