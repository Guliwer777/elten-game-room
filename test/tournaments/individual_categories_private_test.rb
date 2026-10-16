require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'categories', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  move = lambda do |actor, id, choice = nil|
    with_individual_execution(fixture, record, actor) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      choice ||= status['actions'].first
      assert(choice, "Missing action #{id}: #{status.inspect}")
      result = execution.local_game(action: :local_game_move, operation_id: id, revision: status['revision'], move_selection: choice)
      assert_equal(:confirmed, result[:state], result.inspect)
      result
    end
  end
  round = move.call('Beta', 'categories-start')
  assert_equal('answering', round[:status]['phase'])
  move.call('Alpha', 'categories-alpha', {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {}})
  move.call('Beta', 'categories-close')
  first = move.call('Alpha', 'categories-alpha-reveal')
  assert(first[:effect]['record']['packet']['data']['events'].size > 1, 'Answer sheet opens as one multi-event action')
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  assert(!bytes.include?(T::GameSelection::MARKER), 'Private envelope leaked into shared history')
  %w[Alpha Beta].each do |actor|
    with_individual_execution(fixture, record, actor) do |execution|
      assert_equal('revealing', execution.local_game(action: :local_game_status)[:status]['phase'])
    end
  end
  assert_equal(bytes, File.binread(path))
end
puts 'PASS Categories private protocol: own answer sheets, typed private envelope selection, multi-event reveal and retained replay proof'
