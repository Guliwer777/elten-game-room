require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'chess', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'chess-complete')
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  coordinates = [[5,1,5,2], [4,6,4,4], [6,1,6,3], [3,7,7,3]]
  coordinates.each_with_index do |(fx,fy,tx,ty), index|
    with_individual_execution(fixture, record, people[index % 2]['username']) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      selection = {'kind' => 'piece_board', 'action' => 'move', 'from_x' => fx, 'from_y' => fy, 'to_x' => tx, 'to_y' => ty}
      result = execution.local_game(action: :local_game_move, operation_id: "chess-move-#{index}", revision: status['revision'], move_selection: selection)
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal(index + 1, result[:status]['event_count'])
      assert_equal(result[:effect], execution.local_game(action: :local_game_move, operation_id: "chess-move-#{index}", revision: status['revision'], move_selection: selection)[:effect])
    end
  end
  with_individual_execution(fixture, record, people.first['username']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal([people[1]['account']], result[:effect]['summary']['winners'])
    assert_equal(true, execution.progress['complete'])
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  assert_equal({}, JSON.parse(bytes)['busy'])
  probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'chess', 'chess-complete', '4', '1'], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
end
puts 'PASS complete tournament chess: game-owned four-move checkmate, idempotent Runner moves, actual winner, busy release, standings and cold read-only archive'
