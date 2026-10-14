require_relative 'tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport

fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'domino', reopen: true)
begin
  directory = File.join(fixture.directory, 'team-plans')
  backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables,
    journal: fixture.journal, actor: 'Organizator', registry: fixture.registry, clock: -> { fixture.now })
  record = backend.readback(intent_id: 'generic-teams')
  assert_equal(T::GameResult::RESULT_EXPORT_POLICY, record['evidence']['source']['result_policy'])
  path = File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')
  bytes = File.binread(path)
  state = JSON.parse(bytes)
  assert_equal({}, state['busy'])
  assert_equal(1, state['native']['creates'].size)
  row = state['executions'].values.first
  assert(row.fetch('moves').size > 26, 'Cold proof requires the genuinely completed Domino history')
  with_declared_team_execution(fixture, record, row.fetch('coordinator')) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(true, status['finished'])
    progress = execution.progress
    assert_equal(true, progress['complete'])
    assert_equal([2, 2], progress['standings'].map { |unit| unit['points'] }.sort.reverse)
  end
  assert_equal(bytes, File.binread(path))
  core = state['native']['cores'].first
  current = T::LocalGameResult.summary(row, core, registry: fixture.registry, result_policy: T::GameResult::DRAW_RESULT_POLICY)
  assert_equal(true, current['draw'])
  assert_equal([], current['winners'])
  table = T::Standings.calculate(units: current['participants'],
    results: [current.slice('participants', 'winners', 'scores').merge('id' => 'current-policy-projection')], points: T::Standings::MATCH_POINTS)
  assert_equal([1, 1], table.map { |unit| unit['points'] })
  assert_equal(bytes, File.binread(path))
  puts 'PASS cold generic team Domino: unchanged v2 archive; genuine tied replay projects to 1/1 under new v3 policy'
ensure
  fixture.close
end
