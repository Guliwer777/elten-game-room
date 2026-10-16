# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class OgraniczonyCoreFT2Completion < TournamentFixedTeamNativeService
  def limits; super.merge('core_bytes' => 1); end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1/execution-ft2-v1/state.json')
before = File.binread(path); claims = []; creates = []
trace = TracePoint.new(:call) do |p|
  claims << p.method_id if p.defined_class == T::CoordinationJournal && p.method_id == :claim
  creates << p.method_id if p.defined_class == NativeLiveSessionsBroker::Endpoint && p.method_id == :create
end
result = nil
execution_for(context, record, players.first, native_provider: OgraniczonyCoreFT2Completion.new) do |facade|
  select_match(facade, record)
  begin
    trace.enable(target_thread: nil)
    result = facade.request_match
  ensure
    trace.disable
  end
end
oracle_file('native-core-budget.json', {claims: claims, creates: creates, result: result, before: JSON.parse(before), after: JSON.parse(File.binread(path))})
assert(result[:reason] == :native_limits && claims.empty? && creates.empty? && File.binread(path) == before,
  'RED_FT2A_NATIVE_CORE_BUDGET: niższy budżet pełnego native readback musi odmówić przed claim i rzeczywistym create')
puts 'GREEN: pełny native readback ma budżet przed claim i create'
