require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
future = Class.new(GameRoomGames::Farkle) do
  def id; 'future_multi_seat'; end
end
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'future_multi_seat',
  registry: GameRoomGames::Registry.new([future]), reopen: true)
begin
  record = fixture.backend.readback(intent_id: 'automatic-three-seat')
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  state = JSON.parse(bytes)
  assert_equal({}, state['busy'])
  assert_equal(2, state['native']['creates'].size)
  assert_equal(2, state['executions'].values.count { |row| row['result'] })
  state['executions'].values.each do |row|
    request = row['request']
    with_individual_execution(fixture, record, row['coordinator']) do |execution|
      execution.select(intent_id: record['preview']['intent_id'], match_id: request['match_id'],
        leg: request['leg'], window_id: request['window']['id'])
      status = execution.local_game(action: :local_game_status)[:status]
      assert_equal('finished', status['phase'])
      assert_equal(9, status['event_count'])
      assert_equal(true, status['result']['summary']['draw'])
      assert_equal([200, 200, 200], status['result']['summary']['scores'].values.sort)
      assert_equal(Array.new(6, 2), execution.progress['standings'].map { |unit| unit['points'] })
      assert_equal(Array.new(6, 200), execution.progress['standings'].map { |unit| unit['score_for'] })
    end
  end
  assert_equal(bytes, File.binread(path))
  puts 'PASS cold two-table three-seat results: both real histories, all six standings and unchanged archive'
ensure
  fixture.close
end
