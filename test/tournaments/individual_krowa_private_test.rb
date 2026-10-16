require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'krowa', names: %w[Alpha Beta], players_per_match: 2, game_options: {'variant' => 'race', 'length' => 4}) do |fixture|
  record = start_individual_match(fixture)
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    action = status['actions'].first
    assert_equal('prepare', action['action'])
    result = execution.local_game(action: :local_game_move, operation_id: 'krowa-prepare', revision: status['revision'], move_selection: action)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal('active', result[:status]['phase'])
    assert(result[:effect]['randomness'].size > 0, 'Word selection must record its original randomness')
    assert_equal(result[:effect], execution.local_game(action: :local_game_move, operation_id: 'krowa-prepare', revision: status['revision'], move_selection: action)[:effect])
    assert_equal('active', execution.local_game(action: :local_game_status)[:status]['phase'])
  end
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    assert_equal('active', execution.local_game(action: :local_game_status)[:status]['phase'])
    assert_equal(nil, execution.private_choices.reveal(session_id: execution.local_game(action: :local_game_status)[:status]['session_id'], round_id: 'krowa:1', user: 'Alpha'))
  end
  assert_equal(bytes, File.binread(path))
end
puts 'PASS Krowa private random word: missing original envelope reproduced, recorded randomness consumed, multi-event commitment, retries and separate actor vault'
