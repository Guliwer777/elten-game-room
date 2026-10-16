# encoding: UTF-8
require_relative '../support/ft2_fencing_probe'
include FT2FencingProbe
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
all_ready(context, record)
actor = record['evidence']['plan']['matches'].first['players'].first['username']
healthy = nil; before_epoch = nil; after_epoch = nil; calls = nil
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  before_epoch = facade.coordinator_epoch
  effects do |observed|
    calls = observed
    healthy = worker_result('healthy') { facade.request_match }
  end
  after_epoch = facade.coordinator_epoch
end
assert_equal(:bound, healthy[:state])
assert_equal(before_epoch, after_epoch, 'Własny pierwszy reserve nie zmienia epoki')
assert_equal(1, calls.count { |r| r[:method] == :reserve })
assert_equal(1, calls.count { |r| r[:method] == :create_bind })
assert_equal(1, calls.count { |r| r[:method] == :create_room })
assert_equal(0, calls.count { |r| %i[start_game invite].include?(r[:method]) })
assert_equal(1, state(context)['native']['creates'].size)
oracle_file('healthy.json', {result: healthy.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }, before_epoch: before_epoch, after_epoch: after_epoch, calls: calls, state: state(context)})
# Uzgadnianie potwierdzonego skutku ma tę samą końcową ochronę jak request_match.
child = nil; after_child = nil; late = []; stale = nil
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  historical_select(facade, record)
  trace = TracePoint.new(:return) do |event|
    next unless !child && event.defined_class == T::LocalFixedTeamCoordinationPort && event.method_id == :lookup_target
    child = revoke_in_child(context, 'publication-cold')
    after_child = durable_map(context)
  end
  count_effects(late, after_child: -> { !after_child.nil? }) do
    begin
      trace.enable(target_thread: nil)
      stale = worker_result('publication-cold') { outcome { facade.reconcile } }
    ensure
      trace.disable
    end
  end
  assert_equal(:blocked, stale[:state])
  assert_equal(:stale_coordinator, stale[:reason])
  assert_equal([], late)
  assert_equal(after_child, durable_map(context))
end
# Nowa uwierzytelniona próba może przeczytać dawny skutek, nie odzyskuje prawa startu.
cold = nil
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  historical_select(facade, record)
  cold = worker_result('cold-current') { facade.reconcile }
end
assert_equal(:blocked, cold[:state])
assert_equal(:stale_grant, cold[:reason])
assert_equal(after_child, durable_map(context))
assert_equal(1, state(context)['native']['creates'].size)
assert_equal(nil, state(context)['executions'].values.first['grant'])
oracle_file('publication-exact.json', {child: child, stale: stale, late: late, after_child: after_child,
  after_worker: durable_map(context), cold: cold.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }, state: state(context)})
puts 'GREEN: własny reserve zdrowy; stary reconcile nie publikuje; nowy kontekst odczytuje ten sam receipt bez skutku'
