require_relative '../support/quiz_party_review_regressions'
require_relative '../support/hidden_submission_files'
require_relative '../support/session_runner'

class EmptyBotReadStorage < HiddenSubmissionFiles::Storage
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

def observe_empty_bot_preparation(runner)
  counts = {schedule: 0, acquire: 0, planning: 0}
  turn = runner.instance_variable_get(:@turn)
  [:schedule_decision, :acquire].each do |method_name|
    original = turn.method(method_name)
    label = method_name == :schedule_decision ? :schedule : :acquire
    turn.define_singleton_method(method_name) do |**arguments|
      counts[label] += 1
      original.call(**arguments)
    end
  end
  game = runner.instance_variable_get(:@planning_game)
  original = game.method(:prepare_view)
  game.define_singleton_method(:prepare_view) do |*arguments, **options|
    counts[:planning] += 1
    original.call(*arguments, **options)
  end
  counts
end

# An actual bot commits through the native writer, but loses the local file
# before revealing. The empty result must not reacquire the planning lease or
# reread two private files in every 50 ms worker frame.
[:recover, :timeout].each do |outcome|
  Dir.mktmpdir('bot-empty-reveal-') do |directory|
    $quiz_regression_now = 1000
    fixture = QuizReviewFixture.new(['Alice'], bots: 1)
    storage = EmptyBotReadStorage.new(HiddenSubmissionFiles.new(directory))
    vault = HiddenSubmissions::Vault.new(storage)
    fixture.contexts.fetch('Alice').hidden_submissions = vault
    runner = runner_for(fixture.h)
    runner.instance_variable_get(:@context_template).hidden_submissions = vault
    now = 1000.0
    clock = Object.new
    clock.define_singleton_method(:now) { |_session| now.to_i }
    runner.instance_variable_set(:@clock, clock)
    counts = observe_empty_bot_preparation(runner)
    begin
      fixture.h.write('Alice', fixture.plan('Alice').events)
      step(fixture.h, runner)
      bot = fixture.h.replay('Alice').state[:players].find { |player| GameRoomParticipants.bot?(player) }
      envelope = vault.reveal(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: bot)
      assert(envelope, 'The actual bot did not prepare a private answer')
      vault.discard(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: bot)
      step(fixture.h, runner, count: 3)
      assert(fixture.h.replay('Alice').state[:phase] == :revealing, 'Missing-answer setup left reveal phase')
      before_reads, before_counts = storage.reads, counts.dup
      step(fixture.h, runner, count: 20)
      assert(storage.reads == before_reads, 'Unchanged missing bot answer spins private file reads')
      assert(counts == before_counts, 'Empty bot preparation still spins scheduling, leases or planning')

      # A file can recover without a new server revision. Do not cache nil
      # forever; the bounded retry must reveal the exact original commitment.
      if outcome == :recover
        vault.prepare(session_id: envelope.session_id, round_id: envelope.round_id, user: envelope.user,
          payload: envelope.payload, nonce: envelope.nonce)
        runner.instance_variable_set(:@empty_bot_retry_at, 0.0)
        step(fixture.h, runner)
        assert(fixture.h.replay('Alice').state[:reveals][bot] == envelope.payload.fetch('answer').to_i,
          'Recovered bot answer was starved by the empty-decision cache')
      else
        now = 1030.0
        fixture.advance(1030)
        assert(runner.instance_variable_get(:@empty_bot_retry_at) > Process.clock_gettime(Process::CLOCK_MONOTONIC),
          'Deadline test accidentally exhausted the bot retry delay')
      end
      step(fixture.h, runner, count: 2)
      assert(fixture.h.replay('Alice').state[:phase] == :starting, 'Owner scoring was blocked by bot backoff')
      assert(fixture.h.replay('Alice').state[:scores][bot] == 0, 'Missing answer was credited') if outcome == :timeout
    ensure
      runner.close
    end
  end
end

# Framework clock boundary: the real Quiz action remains unchanged, but a
# planning policy exposes it only after a local deadline. No event/revision
# changes between the empty calculation and the available action.
$quiz_regression_now = 1000
fixture = QuizReviewFixture.new(['Alice'], bots: 1)
runner = runner_for(fixture.h)
now = 1000.0
clock = Object.new
clock.define_singleton_method(:now) { |_session| now.to_i }
runner.instance_variable_set(:@clock, clock)
counts = observe_empty_bot_preparation(runner)
planning = runner.instance_variable_get(:@planning_game)
original_actions = planning.method(:legal_actions)
planning.define_singleton_method(:legal_actions) do |replay, actor, context: nil|
  context.now < 1001 ? [] : original_actions.call(replay, actor, context: context)
end
begin
  fixture.h.write('Alice', fixture.plan('Alice').events)
  step(fixture.h, runner)
  revision = runner.send(:revision, fixture.h.replay('Alice'))
  before = counts.dup
  step(fixture.h, runner, count: 20)
  assert(counts == before, 'Clock-gated empty bot calculation spins')
  now = 1001
  runner.instance_variable_set(:@empty_bot_retry_at, 0.0)
  assert(runner.send(:revision, fixture.h.replay('Alice')) == revision, 'Clock test changed the revision')
  step(fixture.h, runner)
  assert(fixture.h.replay('Alice').state[:commitments].length == 2, 'Time-dependent bot action never resumed')
ensure
  runner.close
end

# Isolate each local backoff identity field with prepared native sessions and
# actual runner work. These are preflight checks only: no forged session or
# replay is ever passed to the writer. A new identity must not inherit the
# previous position's empty planning delay.
[:session, :revision, :epoch, :actor].each do |boundary|
  $quiz_regression_now = 1000
  fixture = QuizReviewFixture.new(['Alice'], bots: 2)
  runner = runner_for(fixture.h)
  planning = runner.instance_variable_get(:@planning_game)
  planning.define_singleton_method(:legal_actions) { |*_, **_| [] }
  begin
    fixture.h.write('Alice', fixture.plan('Alice').events)
    step(fixture.h, runner)
    assert(runner.send(:prepare_bot).nil?, 'The same empty position was not deferred')
    session = runner.instance_variable_get(:@session)
    replay = runner.instance_variable_get(:@replay)
    case boundary
    when :session
      session['__id'] += 1
    when :revision
      # A distinct accepted-event prefix, used only by prepare_bot identity.
      replay.accepted_events = replay.accepted_events + [replay.accepted_events.last.merge('__id' => 9_999_999)]
    when :epoch
      session['__control_epoch'] = session['__control_epoch'].to_i + 1
    when :actor
      coordinator = runner.instance_variable_get(:@coordinator)
      alternate = replay.state[:players].select { |player| GameRoomParticipants.bot?(player) }.last
      coordinator.define_singleton_method(:pending_bot) { |*_, **_| alternate }
    end
    work = runner.send(:prepare_bot)
    assert(work, "New #{boundary} inherited an unrelated empty-decision delay")
    runner.instance_variable_get(:@turn).cancel(work.fetch(:lease))
  ensure
    runner.close
  end
end

puts 'PASS empty bot planning: bounded reads/preparation, recovered and time-dependent action, session/revision/epoch/actor isolation'
