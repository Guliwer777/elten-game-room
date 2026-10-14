require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'categories', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    result = execution.local_game(action: :local_game_move, operation_id: 'private-start', revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:confirmed, result[:state])
    assert_equal('answering', result[:status]['phase'])
  end
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  with_individual_execution(fixture, record, 'Organizator') do |execution|
    status = execution.organizer_result_status
    result = execution.organizer_forfeit(operation_id: 'private-forfeit', winner: 'beta', reason: 'Organizer decision', expected_revision: status[:revision])
    assert_equal(:private_phase_pending, result[:reason], result.inspect)
    assert_equal(nil, execution.organizer_result_status[:result])
  end
  assert_equal(bytes, File.binread(path), 'Private-phase refusal changed durable execution')
end
puts 'PASS organizer forfeit respects real Categories private phase and preserves execution'
