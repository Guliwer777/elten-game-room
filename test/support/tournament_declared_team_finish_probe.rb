require_relative 'tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
future = Class.new(GameRoomGames::Spades) do
  def id; 'future_team_cards'; end
end
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'future_team_cards',
  registry: GameRoomGames::Registry.new([future]), reopen: true)
begin
  directory = File.join(fixture.directory, 'team-plans')
  backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables,
    journal: fixture.journal, actor: 'Organizator', registry: fixture.registry, clock: -> { fixture.now })
  record = backend.readback(intent_id: 'future-team-plan')
  path = File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')
  bytes = File.binread(path)
  state = JSON.parse(bytes)
  assert_equal({}, state['busy'])
  assert_equal(1, state['native']['creates'].size)
  row = state['executions'].values.first
  assert(row['moves'].size > 50, 'Cold proof needs the real completed card round')
  with_declared_team_execution(fixture, record, row['coordinator']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(true, status['finished'])
    assert_equal(true, execution.progress['complete'])
    assert_equal([2, 0], execution.progress['standings'].map { |unit| unit['points'] }.sort.reverse)
  end
  assert_equal(bytes, File.binread(path))
  puts 'PASS cold future compatible team game: actual complete card round, common 2/0, unchanged archive'
ensure
  fixture.close
end
