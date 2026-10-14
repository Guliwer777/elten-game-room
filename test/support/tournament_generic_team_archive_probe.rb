require_relative 'tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
game_id, directory = ARGV.fetch(0), ARGV.fetch(1)
registry = GameRoomGames::CATALOG
if game_id == 'future_team_tiles'
  future = Class.new(GameRoomGames::Domino) do
    def id; 'future_team_tiles'; end
  end
  registry = GameRoomGames::Registry.new([future])
end
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(directory, game: game_id, registry: registry, reopen: true)
begin
  plans = File.join(fixture.directory, 'team-plans')
  backend = T::LocalFixedTeamPlanBackend.new(directory: plans, tables: fixture.tables,
    journal: fixture.journal, actor: 'Organizator', registry: fixture.registry, clock: -> { fixture.now })
  record = backend.readback(intent_id: 'generic-teams')
  assert([T::GameResult::DRAW_RESULT_POLICY, T::GameResult::CURRENT_RESULT_POLICY].include?(record['evidence']['source']['result_policy']))
  path = File.join(plans, 'fixed-teams-v1/execution-ft2-v1/state.json')
  bytes = File.binread(path)
  state = JSON.parse(bytes)
  assert_equal({}, state['busy'])
  assert_equal(1, state['native']['creates'].size)
  row = state['executions'].values.first
  assert_equal(game_id, row['request']['game_id'])
  assert(row.fetch('moves').size > 10, 'A genuine completed game history is required')
  summary = row.fetch('result').fetch('summary')
  with_declared_team_execution(fixture, record, row.fetch('coordinator')) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(true, status['finished'])
    progress = execution.progress
    assert_equal(true, progress['complete'])
    if record['preview']['source']['candidate']['format'] == 'knockout'
      assert_equal(summary['draw'] ? 'tie_requires_resolution' : 'completed', progress['knockout_state'])
      assert_equal(summary['draw'] ? nil : summary['winners'].first, progress['champion'])
    end
    progress['standings'].each do |unit|
      expected = summary['draw'] ? 1 : (summary['winners'].include?(unit['team']) ? 2 : 0)
      assert_equal(expected, unit['points'])
      assert_equal(summary['scores'] && summary['scores'][unit['team']], unit['score_for'])
    end
  end
  assert_equal(bytes, File.binread(path))
  puts "PASS cold generic team #{game_id}: genuine replay, 2/1/0, declared small scores and byte-identical archive"
ensure
  fixture.close
end
