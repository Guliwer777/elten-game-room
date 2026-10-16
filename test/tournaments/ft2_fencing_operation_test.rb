# encoding: UTF-8
require_relative '../support/ft2_fencing_probe'
include FT2FencingProbe
# Żądanie create powstaje przez rzeczywisty Service, nie ręczne składanie tokenu.
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
all_ready(context, record)
actor = record['evidence']['plan']['matches'].first['players'].first['username']
operation = nil; child = nil; after_child = nil; result = nil; calls = []
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  trace = TracePoint.new(:call) do |event|
    next unless !child && event.defined_class == T::LocalFixedTeamCoordinationPort && event.method_id == :mutate &&
      event.binding.local_variable_get(:kind) == 'create_bind'
    operation = T::CoordinationContract.copy(event.binding.local_variable_get(:operation))
    T::CoordinationContract.operation!(operation, registry: REGISTRY)
    child = revoke_in_child(context, 'operation')
    after_child = durable_map(context)
  end
  count_effects(calls, after_child: -> { !after_child.nil? }) do
    begin
      trace.enable(target_thread: nil)
      result = worker_result('operation') { outcome { facade.request_match } }
    ensure
      trace.disable
    end
  end
  oracle_file('operation-stale.json', {operation: operation, child: child, result: result, calls: calls,
    after_child: after_child, after_worker: durable_map(context), state: state(context)})
  assert(child && child[:pid] != Process.pid)
  assert_equal(:blocked, result[:state])
  assert_equal(:stale_coordinator, result[:reason])
  assert_equal([], calls, 'Po B zero dalszych metod skutkowych')
  assert_equal(after_child, durable_map(context), 'Żaden trwały plik nie zmienił się po B')
end
# Nowa instancja zna nową epokę; oryginalna legalna operacja nadal nie tworzy celu.
before = durable_map(context)
replayed = nil; fresh = nil
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  facade.coordinator_epoch
  port = facade.instance_variable_get(:@coordination_port)
  replayed = outcome { port.create_bind(operation: operation) }
  fresh = outcome { facade.request_match }
end
oracle_file('operation-reopened.json', {replayed: replayed, fresh: fresh, before: before, after: durable_map(context), state: state(context)})
assert_equal(:blocked, replayed[:state])
assert_equal(:stale_preconditions, replayed[:reason])
assert_equal(:unknown, fresh[:state], 'Attempted bez receipt nie nadaje prawa do ponowienia')
assert_equal(:port_unavailable, fresh[:reason])
assert_equal(operation['operation_id'], fresh[:operation_id])
assert_equal(before, durable_map(context))
assert_equal(0, state(context)['native']['creates'].size)
puts 'GREEN: oryginalny legalny create odrzucony pod lockiem; powrót aktora/ready nie ożywia tokenu'
