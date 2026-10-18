require_relative '../../support/quiz_party_review_regressions'
require_relative '../../support/hidden_submission_files'
require_relative '../../support/session_runner'

# Fail the real private-file read after a commitment has reached the native
# stream. This is not a missing answer or a failed initial save.
class QuizUnreadableAnswers < HiddenSubmissionFiles::Storage
  attr_accessor :unreadable

  private

  def read_snapshot_file(path)
    raise Errno::EACCES, 'simulated private file read lock' if unreadable
    super
  end
end

Dir.mktmpdir('quiz-reveal-read-') do |dir|
  $quiz_regression_now = 1000
  fixture = QuizReviewFixture.new(%w[Alice Bob])
  program = HiddenSubmissionFiles.new(dir)
  storage = QuizUnreadableAnswers.new(program)
  owner_context = fixture.contexts.fetch('Alice')
  owner_context.hidden_submissions = HiddenSubmissions::Vault.new(storage)
  fixture.h.users.each { |user| fixture.h.write(user, fixture.plan(user).events) }
  fixture.auto('Alice')
  fixture.auto('Bob')
  assert(fixture.h.replay('Alice').state[:phase] == :revealing, 'Fixture did not reach reveal')

  storage.unreadable = true
  runner = runner_for(fixture.h)
  runner.instance_variable_get(:@context_template).hidden_submissions = owner_context.hidden_submissions
  # Advance the existing monotonic game clock as well as the broker's time.
  # Moving Time.now alone must not move a running session's anchored clock.
  runner.instance_variable_set(:@clock, GameRoomSessionClock.new(
    sample: -> { $quiz_regression_now }, elapsed: -> { $quiz_regression_now },
    wall: -> { $quiz_regression_now }))
  begin
    step(fixture.h, runner)
    before = fixture.h.events('Alice').size
    assert(fixture.h.replay('Alice').state[:reveals].keys == ['Bob'], 'Read failure fabricated an answer')
    retry_action = fixture.game.automatic_action(fixture.h.replay('Alice'), 'Alice', context: owner_context)
    status, plan = fixture.game.action_for(retry_action, fixture.h.replay('Alice'), 'Alice', context: owner_context)
    assert(status == :local_storage_unavailable && plan.nil?, 'A failed read did not use the bounded retry path')
    fixture.advance(1014)
    step(fixture.h, runner, count: 2)
    assert(fixture.h.events('Alice').size == before, 'Question ended before the existing reveal deadline')

    fixture.advance(1015)
    sleep 1.05 # Existing runner backoff, not a changed game deadline.
    step(fixture.h, runner, count: 3)
    scored = fixture.h.replay('Alice')
    assert(scored.state[:scores] == {'Alice' => 0, 'Bob' => 1}, 'Timeout changed the verified scores')
    assert(scored.state[:phase] == :starting, 'An unreadable owner answer stopped the runner')
    assert(!runner.instance_variable_get(:@internal_error), 'Storage fault became a permanent runner error')
    fixture.h.assert_converged('unreadable owner answer reaches the normal timeout')

    # Recovery does not disclose the stale answer in the next question, nor
    # destroy it while the device is unreadable. New submissions still work.
    storage.unreadable = false
    old = owner_context.hidden_submissions.reveal(session_id: fixture.h.session['__id'],
      round_id: 'round-1-question-1', user: 'Alice')
    assert(old && owner_context.hidden_submissions.verify(old), 'A read failure destroyed the stored answer')
    fixture.advance(1019)
    step(fixture.h, runner, count: 2)
    next_question = fixture.h.replay('Alice')
    assert(next_question.state[:position] == 2 && next_question.state[:commitments].empty? &&
      next_question.state[:reveals].empty?, 'An old answer leaked into the next question')
    fixture.h.users.each { |user| fixture.h.write(user, fixture.plan(user).events) }
    step(fixture.h, runner, count: 2)
    fixture.auto('Bob')
    step(fixture.h, runner, count: 3)
    assert(fixture.h.replay('Alice').state[:scores] == {'Alice' => 1, 'Bob' => 2},
      'The recovered storage failed to reveal and score the next answer')
    fixture.h.assert_converged('answer storage recovery')
  ensure
    runner.close
  end
end

Dir.mktmpdir('quiz-reveal-read-recovery-') do |dir|
  $quiz_regression_now = 1000
  fixture = QuizReviewFixture.new(%w[Alice Bob])
  storage = QuizUnreadableAnswers.new(HiddenSubmissionFiles.new(dir))
  guest_context = fixture.contexts.fetch('Bob')
  guest_context.hidden_submissions = HiddenSubmissions::Vault.new(storage)
  fixture.h.users.each { |user| fixture.h.write(user, fixture.plan(user).events) }
  fixture.auto('Alice')
  fixture.auto('Alice')
  storage.unreadable = true
  runner = runner_for(fixture.h, 'Bob')
  runner.instance_variable_get(:@context_template).hidden_submissions = guest_context.hidden_submissions
  begin
    before = fixture.h.events('Alice').size
    step(fixture.h, runner, 'Bob')
    assert(fixture.h.events('Alice').size == before, 'Read failure wrote an unverified guest answer')
    storage.unreadable = false
    step(fixture.h, runner, 'Bob')
    assert(fixture.h.events('Alice').size == before, 'Retry bypassed the runner backoff')
    sleep 1.05
    step(fixture.h, runner, 'Bob', count: 3)
    assert(fixture.h.replay('Bob').state[:reveals].keys.sort == %w[Alice Bob],
      'A transient file lock lost the answer despite recovery before the deadline')
    fixture.auto('Alice')
    assert(fixture.h.replay('Alice').state[:scores] == {'Alice' => 1, 'Bob' => 1},
      'Recovered guest answer was not counted')
    fixture.h.assert_converged('guest read lock recovery without another move or refresh')
  ensure
    runner.close
  end
end

puts 'PASS Quiz unreadable private answer: real file boundary, owner runner timeout, verified peer score and recovery without stale reveal'
