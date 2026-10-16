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
cause = RuntimeError.new('Przyczyna awarii pliku')
primary = begin
  raise IOError.new('Awaria po skutecznym rename'), cause: cause
rescue IOError => error
  error
end
backtrace = primary.backtrace.dup
active = fired = false
trace = TracePoint.new(:call, :return, :c_return) do |e|
  if e.defined_class == T::LocalFixedTeamExecutionStorage && e.method_id == :write
    active = e.event == :call && e.binding.local_variable_get(:document)['native']['creates'].size == 1
  elsif active && !fired && e.event == :c_return && e.defined_class == File.singleton_class && e.method_id == :rename
    fired = true
    raise primary, cause: primary.cause
  end
end
seen = nil
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  trace.enable(target_thread: nil)
  begin
    seen = facade.request_match
  rescue Exception => error
    seen = error
  ensure
    trace.disable
  end
end
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(path))
receipt = state['executions'].values.first['operations']['create_bind']
actual = {fired: fired, uncertainty: seen.class.name.end_with?('::Unconfirmed'), primary: seen.is_a?(Exception) && seen.cause.equal?(primary),
  cause: primary.cause.equal?(cause), backtrace: primary.backtrace == backtrace,
  receipt: seen.respond_to?(:receipt) && seen.receipt.eql?(receipt), attempt: seen.respond_to?(:attempt_id) && seen.attempt_id.is_a?(String)}
oracle_file('ft2_c08_rename.json', {actual: actual, error_class: seen.class.name, receipt: receipt, state: state})
assert(actual.values.all?, 'RED_FT2A_C08_UNCONFIRMED: niepewny rename musi zachować primary/cause/backtrace oraz detached receipt i attempt')
assert(seen.receipt.frozen? && seen.receipt['operation'].frozen? && seen.attempt_id.frozen?)
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  result = facade.reconcile
  assert_equal(:bound, result[:state])
  assert_equal(receipt['operation_id'], result[:operation_id])
end
assert_equal(1, JSON.parse(File.binread(path))['native']['creates'].size)
puts 'GREEN C08: Unconfirmed po rename, exact pierwotny błąd i readback tej samej operacji'
