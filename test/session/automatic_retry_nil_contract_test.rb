require_relative '../support/quiz_party_review_regressions'
require_relative '../support/hidden_submission_files'
require_relative '../support/session_runner'

class AutomaticRetryReadStorage < HiddenSubmissionFiles::Storage
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

%w[Alice Bob].each do |user|
  [:missing, :available].each do |recovery|
    Dir.mktmpdir('automatic-retry-nil-') do |dir|
      $quiz_regression_now = 1000
      fixture = QuizReviewFixture.new(%w[Alice Bob])
      storage = AutomaticRetryReadStorage.new(HiddenSubmissionFiles.new(dir))
      vault = HiddenSubmissions::Vault.new(storage)
      fixture.contexts.fetch(user).hidden_submissions = vault
      fixture.h.users.each { |player| fixture.h.write(player, fixture.plan(player).events) }
      original = vault.reveal(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: user)
      fixture.auto('Alice')
      assert(fixture.h.replay(user).state[:phase] == :revealing, 'Reveal setup failed')

      runner = runner_for(fixture.h, user)
      runner.instance_variable_get(:@context_template).hidden_submissions = vault
      elapsed = 0.0
      runner.instance_variable_set(:@clock, GameRoomSessionClock.new(
        sample: -> { nil }, elapsed: -> { elapsed }, wall: -> { 1000.0 }))
      storage.unreadable = true
      begin
        before = fixture.h.events(user).size
        step(fixture.h, runner, user)
        assert(runner.instance_variable_get(:@automatic_retry_key), 'Read failure did not request bounded recovery')
        reads = storage.reads
        step(fixture.h, runner, user, count: 20)
        assert(storage.reads == reads, 'The one-second retry delay was bypassed')
        assert(fixture.h.events(user).size == before, 'An unreadable answer was revealed')

        storage.unreadable = false
        if recovery == :missing
          vault.discard(session_id: fixture.h.session['__id'], round_id: 'round-1-question-1', user: user)
        end
        # Advance only the runner's bounded retry; no wall-clock sleep and no
        # change of the game revision or its answer/reveal deadline.
        runner.instance_variable_set(:@automatic_retry_at, 0.0)
        step(fixture.h, runner, user)
        reads = storage.reads
        if recovery == :missing
          assert(fixture.h.events(user).size == before, 'Missing envelope fabricated a reveal')
          step(fixture.h, runner, user, count: 20)
          assert(storage.reads == reads, 'A successful retry with no action kept reading on every tick')
          assert(runner.instance_variable_get(:@automatic_retry_key).nil?, 'Completed empty retry retained its key')
          assert(runner.instance_variable_get(:@automatic_checked), 'Empty retry erased the checked revision')
          if user == 'Alice'
            fixture.advance(1030)
            elapsed = 30.0
            step(fixture.h, runner, user, count: 2)
            replay = fixture.h.replay(user)
            assert(replay.state[:phase] == :starting, 'Clearing an empty retry starved the owner reveal deadline')
            assert(replay.state[:scores] == {'Alice' => 0, 'Bob' => 0}, 'Missing private answers invented points')
          end
        else
          step(fixture.h, runner, user, count: 3)
          replay = fixture.h.replay(user)
          assert(replay.state[:reveals][user] == original.payload.fetch('answer').to_i,
            'A real recovered envelope no longer revealed the committed answer')
          assert(runner.instance_variable_get(:@automatic_retry_key).nil?, 'Successful reveal retained retry')
          count = fixture.h.events(user).size
          fixture.h.broker.deliver(duplicate: true)
          step(fixture.h, runner, user, count: 3)
          assert(fixture.h.events(user).size == count, 'Recovered reveal was repeated')
        end
      ensure
        runner.close
      end
    end
  end
end

puts 'PASS automatic retry: unreadable to missing is checked once; owner deadline and recovered reveals remain active'
