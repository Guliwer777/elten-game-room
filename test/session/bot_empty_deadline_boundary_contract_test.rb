require_relative '../support/quiz_party_review_regressions'
require_relative '../support/hidden_submission_files'
require_relative '../support/session_runner'

# Exercise the elapsed-time boundary itself. Do not mutate the runner's retry
# state: a real private envelope must recover without a new game event.
module BotEmptyBoundaryClock
  class << self
    attr_accessor :now
  end

  def clock_gettime(clock_id, *arguments)
    if clock_id == Process::CLOCK_MONOTONIC && arguments.empty? && BotEmptyBoundaryClock.now
      BotEmptyBoundaryClock.now
    else
      super
    end
  end
end
Process.singleton_class.prepend(BotEmptyBoundaryClock)

class BotEmptyBoundaryStorage < HiddenSubmissionFiles::Storage
  attr_reader :reads

  def initialize(program)
    super
    @reads = 0
  end

  private

  def read_snapshot_file(path)
    @reads += 1
    super
  end
end

Dir.mktmpdir('bot-empty-deadline-boundary-') do |directory|
  BotEmptyBoundaryClock.now = 500.0
  $quiz_regression_now = 1000
  fixture = QuizReviewFixture.new(['Alice'], bots: 1)
  storage = BotEmptyBoundaryStorage.new(HiddenSubmissionFiles.new(directory))
  vault = HiddenSubmissions::Vault.new(storage)
  fixture.contexts.fetch('Alice').hidden_submissions = vault
  runner = runner_for(fixture.h)
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  clock = Object.new
  clock.define_singleton_method(:now) { |_session| 1000 }
  runner.instance_variable_set(:@clock, clock)
  planning = runner.instance_variable_get(:@planning_game)
  prepare_view = planning.method(:prepare_view)
  calculations = 0
  planning.define_singleton_method(:prepare_view) do |*arguments, **options|
    calculations += 1
    prepare_view.call(*arguments, **options)
  end

  begin
    fixture.h.write('Alice', fixture.plan('Alice').events)
    step(fixture.h, runner)
    bot = fixture.h.replay('Alice').state[:players].find { |player| GameRoomParticipants.bot?(player) }
    envelope = vault.reveal(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: bot)
    assert(envelope, 'The native bot did not commit its own private answer')
    vault.discard(session_id: envelope.session_id, round_id: envelope.round_id, user: bot)
    step(fixture.h, runner, count: 3)
    assert(fixture.h.replay('Alice').state[:phase] == :revealing, 'The setup did not reach the missing bot reveal')
    before_reads, before_calculations = storage.reads, calculations
    before_events = fixture.h.events('Alice').length

    (1..19).each do |frame|
      BotEmptyBoundaryClock.now = 500.0 + frame * 0.05
      step(fixture.h, runner)
    end
    BotEmptyBoundaryClock.now = 500.999
    step(fixture.h, runner)
    assert(storage.reads == before_reads, 'The unchanged bot reread private files before one full second')
    assert(calculations == before_calculations, 'The unchanged bot recalculated before one full second')

    BotEmptyBoundaryClock.now = 501.0
    step(fixture.h, runner)
    assert(calculations == before_calculations + 1, 'The empty decision was not retried at the exact deadline')
    assert(storage.reads > before_reads && storage.reads <= before_reads + 2,
      'One bounded retry made an unexpected number of private file reads')
    after_retry_reads, after_retry_calculations = storage.reads, calculations
    step(fixture.h, runner, count: 20)
    assert(storage.reads == after_retry_reads && calculations == after_retry_calculations,
      'The second missing result did not start a new bounded backoff')
    assert(fixture.h.events('Alice').length == before_events, 'An empty bot decision wrote a server event')

    vault.prepare(session_id: envelope.session_id, round_id: envelope.round_id, user: envelope.user,
      payload: envelope.payload, nonce: envelope.nonce)
    recovered_reads = storage.reads
    BotEmptyBoundaryClock.now = 501.999
    step(fixture.h, runner)
    assert(storage.reads == recovered_reads && calculations == after_retry_calculations,
      'Recovering a file restarted planning before the established deadline')
    BotEmptyBoundaryClock.now = 502.0
    step(fixture.h, runner)
    replay = fixture.h.replay('Alice')
    assert(replay.state[:reveals][bot] == envelope.payload.fetch('answer').to_i,
      'The original committed answer did not reveal when its file recovered')
    assert(calculations == after_retry_calculations + 1, 'Recovery performed more than one planning calculation')
    written = fixture.h.events('Alice').drop(before_events)
    assert(written.map { |event| event['action'] } == %w[answer_nonce answer_pick],
      'Recovery did not write exactly one complete reveal plan')
    repository = fixture.h.repositories.fetch('Alice')
    assert(written.all? { |event| repository.actor_of(event, fixture.h.session) == bot },
      'Recovery changed the author of the private answer')
    step(fixture.h, runner, count: 2)
    assert(fixture.h.replay('Alice').state[:phase] == :starting, 'Scoring stopped after the bounded recovery')
  ensure
    runner.close
    BotEmptyBoundaryClock.now = nil
  end
end

puts 'PASS bot empty decision: exact 1-second boundary, bounded repeat, original private reveal and normal scoring'
