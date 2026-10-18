require_relative '../../support/quiz_party_review_regressions'
require_relative '../../support/hidden_submission_files'
require_relative '../../support/session_runner'

class QuizReopenAnswerStorage < HiddenSubmissionFiles::Storage
  attr_accessor :unreadable
  attr_reader :reads

  def initialize(program)
    super
    @reads = 0
  end

  private

  def read_snapshot_file(path)
    @reads += 1
    raise Errno::EACCES, 'temporary private answer read lock' if unreadable
    super
  end
end

Dir.mktmpdir('quiz-reopen-read-boundary-') do |dir|
  $quiz_regression_now = 1000
  fixture = QuizReviewFixture.new(%w[Alice Bob])
  storage = QuizReopenAnswerStorage.new(HiddenSubmissionFiles.new(dir))
  vault = HiddenSubmissions::Vault.new(storage)
  fixture.contexts.fetch('Bob').hidden_submissions = vault
  fixture.h.users.each { |user| fixture.h.write(user, fixture.plan(user).events) }
  original = vault.reveal(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: 'Bob')
  assert(original && vault.verify(original), 'The original answer was not stored')

  # A newer local edit is not the answer whose commitment was accepted.
  newer = vault.prepare(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: 'Bob',
    payload: {'answer' => ((original.payload.fetch('answer').to_i + 1) % 4).to_s})
  assert(newer.commitment != original.commitment, 'The fixture did not retain two versions')
  fixture.auto('Alice')
  fixture.auto('Alice')
  assert(fixture.h.replay('Alice').state[:phase] == :revealing, 'The reveal phase was not reached')
  storage.unreadable = true
  runner = runner_for(fixture.h, 'Bob')
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  begin
    before = fixture.h.events('Bob').size
    step(fixture.h, runner, 'Bob')
    assert(fixture.h.events('Bob').size == before, 'Read failure fabricated a reveal')
    assert(runner.instance_variable_get(:@automatic_retry_key), 'A read failure permanently consumed the automatic check')
    assert(!runner.instance_variable_get(:@internal_error), 'A read failure stopped the runner')
    reads = storage.reads
    step(fixture.h, runner, 'Bob', count: 20)
    assert(storage.reads == reads, 'The bounded backoff reread the unavailable file on every tick')
    assert(fixture.h.events('Bob').size == before, 'Retry ticks wrote a reveal without a private answer')
  ensure
    runner.close
  end

  # Recreate both vault and runner from the same real private files. Neither
  # an in-memory answer cache nor the newer, uncommitted draft may win.
  recovered = HiddenSubmissions::Vault.new(QuizReopenAnswerStorage.new(HiddenSubmissionFiles.new(dir)))
  runner = runner_for(fixture.h, 'Bob')
  runner.instance_variable_get(:@context_template).hidden_submissions = recovered
  begin
    step(fixture.h, runner, 'Bob', count: 3)
    replay = fixture.h.replay('Bob')
    assert(replay.state[:reveals]['Bob'] == original.payload.fetch('answer').to_i,
      'Cold recovery revealed the wrong local version')
    assert(replay.state[:reveals]['Bob'] != newer.payload.fetch('answer').to_i,
      'An uncommitted edit replaced the accepted answer')
    accepted = fixture.h.events('Bob').size
    fixture.h.broker.deliver(duplicate: true)
    step(fixture.h, runner, 'Bob', count: 4)
    assert(fixture.h.events('Bob').size == accepted, 'Duplicate delivery produced a second reveal')
    fixture.auto('Alice')
    assert(fixture.h.replay('Alice').state[:scores] == {'Alice' => 1, 'Bob' => 1},
      'The committed answer was not scored exactly once')
    fixture.h.assert_converged('cold private answer recovery')
    fixture.advance(1004)
    fixture.auto('Alice')
    step(fixture.h, runner, 'Bob', count: 3)
    replay = fixture.h.replay('Bob')
    assert(replay.state[:position] == 2 && replay.state[:commitments].empty? && replay.state[:reveals].empty?,
      'The earlier private answer escaped into the next question')
    fixture.h.assert_converged('no stale private answer after recovery')
  ensure
    runner.close
  end
end

puts 'PASS Quiz read lock: bounded retry, cold private-file reopen, original commitment version, duplicates and next-question isolation'
