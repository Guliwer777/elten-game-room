require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'four_in_a_row', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'four-complete')
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  [0,1,0,1,0,1,0].each_with_index do |column, index|
    with_individual_execution(fixture, record, people[index % 2]['username']) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      effect = execution.local_game(action: :local_game_move, operation_id: "drop-#{index}", revision: status['revision'],
        move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => column, 'y' => 0})
      assert_equal(:confirmed, effect[:state], effect.inspect)
      assert_equal(index + 1, effect[:status]['event_count'])
    end
  end
  with_individual_execution(fixture, record, people.first['username']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal([people.first['account']], result[:effect]['summary']['winners'])
    assert_equal(true, execution.progress['complete'])
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  assert_equal({}, JSON.parse(bytes)['busy'])
  probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'four_in_a_row', 'four-complete', '7', '0'], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
end
puts 'PASS complete tournament Four in a row: real board with nil state, actual winner, busy release, standings and cold read-only result'
