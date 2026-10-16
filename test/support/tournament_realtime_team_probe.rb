require_relative 'tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
directory, id, phase = ARGV
registry = id == 'future_realtime_team' ? GameRoomGames::Registry.new([Class.new(GameRoomGames::AxelPong) do
  def id; 'future_realtime_team'; end
end]) : GameRoomGames::CATALOG
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(directory, reopen: true, game: id, registry: registry)
path = File.join(directory, 'team-plans/fixed-teams-v1/execution-ft2-v1/state.json')
before = File.binread(path)
begin
  record = nil
  with_declared_team_backend(fixture, 'Organizator') { |backend, _authority, _directory| record = backend.readback(intent_id: 'realtime-teams') }
  owner = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }.first['username']
  with_declared_team_execution(fixture, record, owner) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    if phase == 'running'
      assert(!status['finished'], 'A partial archive must remain unfinished')
      assert_equal(3, status['event_count'])
      assert(status['standings'].all? { |row| row['points'].zero? }, 'Partial points must not award a tournament victory')
      state = JSON.parse(File.binread(path))
      assert_equal(4, state['busy'].size)
      assert_equal(1, state['native']['creates'].size)
    else
      assert(status['finished'])
      assert_equal(7, status['event_count'])
      assert_equal([2, 0], status['standings'].map { |row| row['points'] }.sort.reverse)
    end
  end
  assert_equal(before, File.binread(path))
ensure
  fixture.close
end
puts "PASS independent realtime team archive (#{phase || 'finished'}): sealed full-team source, agreed contexts, phase-appropriate scoring and exact bytes preserved"
