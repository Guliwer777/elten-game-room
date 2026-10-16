require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
# This scenario checks sealed answers, not real-time expiry. Replaying the
# persistent tournament history must not consume the players' answer window.
# Each scenario runs in its own process, so the fixed clock stays test-local.
QUIZ_PRIVATE_NOW = Time.now
Time.singleton_class.prepend(Module.new do
  def now; QUIZ_PRIVATE_NOW; end
end)
with_fixture(game: 'quiz', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  move = lambda do |actor, id, action = nil|
    with_individual_execution(fixture, record, actor) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      action ||= status['actions'].first
      assert(action, "Missing own action #{id}: #{status.inspect}")
      result = execution.local_game(action: :local_game_move, operation_id: id, revision: status['revision'], move_selection: action)
      assert_equal(:confirmed, result[:state], result.inspect)
      result
    end
  end
  move.call('Beta', 'quiz-draw')
  move.call('Beta', 'quiz-category')
  question = move.call('Beta', 'quiz-question')
  assert_equal('answering', question[:status]['phase'])
  move.call('Alpha', 'quiz-alpha-answer')
  move.call('Beta', 'quiz-beta-answer')
  closed = move.call('Beta', 'quiz-close')
  assert_equal('revealing', closed[:status]['phase'])
  move.call('Alpha', 'quiz-alpha-reveal')
  move.call('Beta', 'quiz-beta-reveal')
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  assert(!bytes.include?('"question_id"'), 'Raw private answer selection leaked into shared receipts')
  2.times do
    %w[Alpha Beta].each do |actor|
      with_individual_execution(fixture, record, actor) do |execution|
        status = execution.local_game(action: :local_game_status)[:status]
        assert_equal('revealing', status['phase'])
        assert_equal('private', status['last_move']['selection']['kind'])
      end
    end
    assert_equal(bytes, File.binread(path))
  end
end
puts 'PASS Quiz private answers: game-owned choices, timed question, own sealed answer/reveal and read-only historical validation after game discard'
