require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'krowa', names: %w[Alpha Beta], rematch: false,
  players_per_match: 2, game_options: {'variant' => 'race', 'length' => 4}) do |fixture|
  record = start_individual_match(fixture, intent_id: 'krowa-complete')
  move = lambda do |actor, id, choice = nil|
    with_individual_execution(fixture, record, actor) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      choice ||= status['actions'].first
      assert(choice, "Missing legal action #{id}")
      result = execution.local_game(action: :local_game_move, operation_id: id,
        revision: status['revision'], move_selection: choice)
      assert_equal(:confirmed, result[:state], result.inspect)
      result
    end
  end
  move.call('Beta', 'krowa-finish-prepare')
  # Test oracle reads only the founder's own private envelope. The competing
  # actor has no such envelope; all guesses/evaluations still use the real game.
  word = nil
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    word = execution.private_choices.reveal(session_id: status['session_id'], round_id: 'krowa:1', user: 'Beta').payload['word']
  end
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(nil, execution.private_choices.reveal(session_id: status['session_id'], round_id: 'krowa:1', user: 'Alpha'))
  end
  move.call('Alpha', 'krowa-finish-guess', {'kind' => 'question', 'action' => 'submit', 'question_id' => 'krowa-answer-1', 'answer' => word})
  move.call('Beta', 'krowa-finish-evaluate')
  move.call('Beta', 'krowa-finish-surrender', {'kind' => 'command', 'action' => 'surrender'})
  move.call('Beta', 'krowa-finish-reveal')
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(['alpha'], result[:effect]['summary']['winners'])
    assert_equal(nil, result[:effect]['summary']['scores'])
    assert_equal([2, 0], execution.progress['standings'].map { |row| row['points'] })
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    bytes = File.binread(path)
    assert_equal({}, JSON.parse(bytes)['busy'])
    probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'krowa', 'krowa-complete', status['event_count'].to_s, 'alpha'], err: [:child, :out], &:read)
    assert($?.success?, output)
    assert_equal(bytes, File.binread(path))
  end
end
puts 'PASS complete tournament Krowa: private random word, real guess/evaluation, game-owned surrender, common 2/0 result without invented small scores and cold archive'
