# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class OgraniczonyProviderFT2A < TournamentFixedTeamNativeService
  def limits
    super.merge('options_bytes' => 1)
  end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
root = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1')
state = File.binread(File.join(root, 'state.json'))
claims = []
trace = TracePoint.new(:call) do |point|
  claims << point.method_id if point.defined_class == T::CoordinationJournal && point.method_id == :claim
end
result = nil
begin
  trace.enable(target_thread: nil)
  execution_for(context, record, players.first, native_provider: OgraniczonyProviderFT2A.new) do |facade|
    select_match(facade, record)
    result = facade.request_match
  end
ensure
  trace.disable
end
assert_equal(:native_limits, result[:reason], 'Osiągnięta rzeczywista bramka limitu providera')
oracle_file('limits-before-assert.json', {claims: claims, result: result, before: JSON.parse(state), after: JSON.parse(File.binread(File.join(root, 'state.json')))})
assert_equal([], claims, 'RED_FT2A_BUDZET: niższy limit native musi odmówić przed claim, nie po reserve')
assert_equal(state, File.binread(File.join(root, 'state.json')), 'Odmowa nie zapisuje nawet nowej epoki')
puts 'GREEN: niższy budżet native odmawia przed claim i bez zmiany zdrowego state'
