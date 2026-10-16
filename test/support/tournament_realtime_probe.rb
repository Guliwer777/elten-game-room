require_relative 'tournament_individual_execution'
require_relative '../../lib/tournaments/local_realtime_individual_execution'
include TournamentIndividualExecutionSupport
directory = ARGV.fetch(0)
path = File.join(directory, 'k02/individual-v1/execution-v1/state.json')
before = File.binread(path)
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(directory, reopen: true, game: ARGV[1] || 'axel_pong')
begin
  record = fixture.backend.readback(intent_id: ARGV[2] || 'local-realtime-game')
  actor = record['evidence']['plan']['matches'].first['players'].first['username']
  with_individual_execution(fixture, record, actor, execution_class: T::LocalRealtimeIndividualExecution) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert(status['finished'], 'Independent process must verify actual finished realtime history')
    assert_equal(Integer(ARGV[3] || 7), status['event_count'])
    assert_equal([2, 0], status['standings'].map { |row| row['points'] }.sort.reverse)
  end
  assert_equal(before, File.binread(path), 'Archive verification must preserve exact bytes')
ensure
  fixture.close
end
puts 'PASS independent realtime archive: all agreed point contexts and real final result verified, exact bytes preserved'
