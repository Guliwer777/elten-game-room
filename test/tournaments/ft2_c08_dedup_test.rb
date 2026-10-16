# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert_equal(:bound, facade.request_match[:state])
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
healthy = File.binread(path)
document = JSON.parse(healthy)
document['native']['cores'].first['dedup'] = []
bytes = JSON.generate(document)
File.binwrite(path, bytes)
mutations = []
trace = TracePoint.new(:call) do |e|
  mutations << [e.defined_class.to_s, e.method_id] if
    ([T::ReadinessJournal, T::CoordinationJournal].include?(e.defined_class) && e.method_id == :claim) ||
    (e.defined_class == TournamentFixedTeamNativeService::Broker::Endpoint && e.method_id == :create)
end
result = nil
trace.enable(target_thread: nil)
begin
  other_players = record['evidence']['plan']['matches'].fetch(1)['players'].map { |p| p['username'] }
  execution_for(context, record, (players & other_players).first) do |facade|
    select_match(facade, record, 1)
    result = facade.declare(availability: 'ready', expected_revision: 0)
  end
ensure
  trace.disable
end
expected = {state: :blocked, reason: :sandbox_corrupt, current: nil, receipt: nil, operation_id: nil}
actual = {result: result, exact: File.binread(path) == bytes.b, mutations: mutations}
oracle_file('ft2_c08_dedup.json', {expected: {result: expected, exact: true, mutations: []}, actual: actual, healthy: JSON.parse(healthy), corrupted: document})
assert_equal({result: expected, exact: true, mutations: []}, actual, 'RED_FT2A_C08_DEDUP: niezaznaczony core wymaga pełnej relacji dedup przed nowym claim')
puts 'GREEN C08: dedup całego stanu sprawdzony przed nowym declare/claim'
