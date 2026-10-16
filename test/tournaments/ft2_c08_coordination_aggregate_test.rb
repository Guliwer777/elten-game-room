# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
projections = []; boundaries = []
trace = TracePoint.new(:return, :call) do |e|
  if e.event == :return && e.defined_class == T::Publication::Data.singleton_class && e.method_id == :copy
    v = e.return_value
    if v.is_a?(Hash) && v.keys.sort == %w[busy executions identity native readiness records version]
      projections << JSON.parse(JSON.generate(v))
    end
  elsif e.event == :call && ((e.defined_class == T::CoordinationJournal && e.method_id == :claim) ||
      (e.defined_class == TournamentFixedTeamNativeService::Broker::Endpoint && e.method_id == :create))
    kind = e.method_id == :claim ? e.binding.local_variable_get(:operation)['kind'] : 'working_create'
    boundaries << {kind: kind, projections: JSON.parse(JSON.generate(projections))}
    projections.clear
  end
end
result = nil
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  trace.enable(target_thread: nil)
  begin
    result = facade.request_match
  ensure
    trace.disable
  end
end
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(path))
oracle_file('ft2_c08_coordination_aggregate.json', {boundaries: boundaries, actual: state, result: result.merge(binding: result[:binding]&.to_h, target: result[:target]&.to_h)})
assert_equal(:bound, result[:state])
assert_equal(%w[reserve create_bind working_create], boundaries.map { |r| r[:kind] })
boundaries.each do |boundary|
  expected_kind = boundary[:kind] == 'reserve' ? 'reserve' : 'create_bind'
  assert(boundary[:projections].any? do |p|
    p['executions'].values.any? { |e| e['operations'].key?(expected_kind) } &&
      (expected_kind == 'reserve' || p['native']['cores'].size == 1)
  end, "RED_FT2A_C08_COORD_AGGREGATE: pełny przyszły agregat przed #{boundary[:kind]}")
end
assert_equal(result[:target].to_h, state['executions'].values.first['target'])
puts 'GREEN C08: pełny agregat przed każdym claim i working native create'
