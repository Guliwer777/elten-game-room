require 'fileutils'
require_relative '../../support/ui'
require_relative '../../../lib/game_surfaces'
require_relative '../../support/duck_game_adapter'
require_relative '../../support/session_runner'
require_relative '../../support/duck_legacy_flow'
require_relative '../../support/hidden_submission_files'

# Real game/repository/codec/executor; only the native network and clock are
# local fixtures. The two human accounts have separate answer vaults.
module DuckPrivateRunnerTest
  include DuckGameAdapterTest
  Clock = Struct.new(:value) do
    def now(_session); value.to_i; end
    def now_f(_session); value; end
  end

  class Harness
    include DuckPrivateRunnerTest
    attr_reader :native, :game, :runners, :clock, :resources, :calls, :players, :owner

    def initialize(kind: 'rhythm', covered: true, spectator_host: false, stack_entry_bytes: 16_384, simon_levels: 12)
      @simon_levels = simon_levels
      seed_fixture = DuckGameAdapterTest::Harness.new(kind: kind)
      @resources = seed_fixture.resources
      @game = DuckLegacyFlowGame.new(resources: @resources)
      @players, @owner = %w[Alice Bob], spectator_host ? 'Watcher' : 'Alice'
      users = spectator_host ? [owner] + players : players
      options = game.default_options.merge('challenges' => [kind], 'bot_delay' => 0)
      @native = NativeHarness.new(game: game, users: users, options: options)
      @native.core.stack_entry_bytes = stack_entry_bytes
      if spectator_host
        native.as(owner) { native.transports[owner].set_observer(native.table, true, actor: owner) }
        session = native.as(owner) do
          native.repositories[owner].start_session(table: native.table, game: game.id,
            players: players, options: JSON.generate(options), recipients: users)
        end
        native.instance_variable_set(:@session, session)
      else
        native.start
      end
      @clock, @calls = Clock.new(1_000.0), []
      @runners = native.users.to_h do |user|
        runner = runner_for(native, user, covered: -> { covered })
        runner.instance_variable_set(:@clock, clock)
        runner.instance_variable_get(:@turn).instance_variable_set(:@clock, -> { clock.value })
        template = runner.instance_variable_get(:@context_template)
        template.random_source = SeedSource.new(seed_fixture.seed_for('super_challenge'))
        template.local_data = local(user)
        observed_game = runner.instance_variable_get(:@game)
        original, calls = observed_game.method(:automatic_action), @calls
        observed_game.define_singleton_method(:automatic_action) do |replay, actor, context: nil|
          result = original.call(replay, actor, context: context)
          calls << {user: user, revision: replay.state[:revision],
            phase: replay.state.dig(:round, :private, :phase), selection: result&.fetch('action'),
            request: context.local_data.to_h.dig('duck_action', 'action')}
          result
        end
        [user, runner]
      end
      native.view(owner).next_random_values = SeedSource.new(seed_fixture.seed_for('super_challenge')).roll(count:16,sides:256).values
      tick(owner)
      assert(replay.state[:race], 'The host executor did not start the race')
      card = replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'super_challenge' }
      submit('Alice', {'kind' => 'duck', 'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id}})
      12.times do
        break if replay.state.dig(:round, :phase) == :playing
        native.users.each { |user| tick(user) }
      end
      assert_equal(:playing, replay.state.dig(:round, :phase))
    rescue Exception
      close
      raise
    end

    def local(user, request = nil)
      {'duck_host' => user == owner, 'duck_seat' => players.index(user),
        'duck_ready' => true, 'duck_action' => request,
        'duck_stack_entry_bytes' => native.transports.fetch(user).game_action_limits(native.table)['max_stack_entry_bytes']}
    end

    def replay(user = 'Alice'); native.replay(user); end
    def vault(user); runners.fetch(user).instance_variable_get(:@context_template).hidden_submissions; end

    def publish(user, request = nil)
      runner = runners.fetch(user)
      context = runner.send(:context)
      context.local_data = local(user, request)
      runner.publish_view(session: native.session, replay: replay(user), busy: false, context: context)
    end

    def tick(user, publish: true, delta: 0.01)
      clock.value += delta
      self.publish(user) if publish
      step(native, runners.fetch(user), user)
      assert_equal(native.events(user).length, replay(user).accepted_events.length,
        'The executor wrote an action rejected by replay')
    end

    def submit(user, selection)
      status, = native.as(user) do
        runners.fetch(user).submit(session: native.session, replay: replay(user), selection: selection, actor: user)
      end
      assert_equal(:ok, status, "Rejected human action #{selection['action']}")
    end

    def traces
      round = replay.state[:round]
      round[:challenge][:participants].to_h do |seat|
        trace = LOGIC::ChallengeTrace.new(round[:challenge], seat: seat, resources: resources)
        if round[:challenge][:kind] == 'rhythm'
          stimulus = LOGIC::ChallengeEngine.stimulus(trace.state, seat: seat)
          onsets = stimulus[:events].map { |event| event[:offset_ms] + 30 + seat * 10 }
          heard_until = onsets.last + 200
          assert(trace.submit({kind: :playback_finished, playback_id: stimulus[:id], onsets_ms: onsets}, at: heard_until))
          start = heard_until + 300
          assert(trace.submit({kind: :begin, press_id: 1}, at: start))
          stimulus[:events].each_with_index do |event, index|
            assert(trace.submit({kind: :tone, value: event[:tone], press_id: index + 2},
              at: start + 200 + onsets[index] - onsets.first))
          end
        elsif round[:challenge][:kind] == 'simon'
          time, press = 0, 0
          loop do
            stimulus = LOGIC::ChallengeEngine.stimulus(trace.state, seat: seat)
            events = stimulus.fetch(:events)
            time = stimulus[:requested_ms] + events.last[:offset_ms] + events.last[:duration_ms] + 30
            assert(trace.submit({kind: :playback_finished, playback_id: stimulus[:id]}, at: time))
            if events.length > @simon_levels + seat
              assert(trace.submit({kind: :tone, value: events.first[:tone] % 5 + 1,
                press_id: press += 1}, at: time += 150))
              break
            end
            events.each do |event|
              assert(trace.submit({kind: :tone, value: event[:tone], press_id: press += 1}, at: time += 150))
            end
          end
        elsif round[:challenge][:kind] == 'quiz'
          assert(trace.submit({kind: :answer, value: trace.state[:model][:question][:correct_index],
            press_id: 1}, at: 300 + seat * 200))
        else
          raise "Missing private runner trace: #{round[:challenge][:kind]}"
        end
        assert(trace.finished?)
        [seat, trace.snapshot]
      end
    end

    def commit_attempts
      round = replay.state[:round]
      values = traces
      clock.value = (round[:started_at] + values.values.map { |trace| trace['finished_at'] }.max + 100) / 1000.0
      players.reverse.each do |user|
        seat = players.index(user)
        submit(user, {'kind' => 'duck', 'action' => 'submit_trace',
          'challenge' => round[:challenge][:id], 'trace' => values.fetch(seat)})
      end
      assert_equal([0, 1], replay.state[:round][:private][:commitments].keys.sort)
      tick(owner)
      assert_equal(:revealing, replay.state[:round][:private][:phase])
    end

    def close
      runners&.each_value(&:close)
      native&.as(owner) { native.view(owner)&.close }
    end

    # Model the observed runner checkpoint: this exact revision has already
    # been consulted and no local key request remains. No game data is changed.
    def mark_revision_checked(user)
      runner = runners.fetch(user)
      current = replay(user)
      runner.instance_variable_set(:@automatic_checked, [native.session.fetch('__id'),
        runner.send(:revision, current), runner.instance_variable_get(:@session)['__control_epoch']])
    end
  end
end

include GameRoomTest::Assertions
cases = []
check = lambda do |name, &block|
  value = block.call
  cases << {name: name, status: 'PASS', details: value}
rescue StandardError => error
  cases << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", location: error.backtrace.first(6)}
end

%w[quiz rhythm].each do |kind|
  [true, false].each do |covered|
    check.call("#{kind}: independent human executors reveal on the first revision check, covered=#{covered}") do
      h = DuckPrivateRunnerTest::Harness.new(kind: kind, covered: covered)
      begin
        h.commit_attempts
        8.times do
          break if h.replay.state[:last_resolution]
          h.native.users.each { |user| h.tick(user) }
        end
        assert(h.replay.state[:last_resolution], "Private uploads stalled: #{h.calls.inspect}")
        assert(h.replay.state[:last_resolution][:settlement], 'The private challenge was cancelled')
        assert_equal(100, h.replay.state[:last_resolution][:results][0][:score]) if kind == 'rhythm'
        h.players.each { |user| h.tick(user) }
        h.players.each do |user|
          assert_equal([], h.vault(user).envelopes(session_id: h.replay.state[:session_id],
            user: user, round_prefix: 'duck:'), 'The shared worker retained a confirmed local answer')
        end
        h.calls
      ensure
        h.close
      end
    end
  end
end

check.call('pending reveal remains due without keyboard input and without touching the private vault') do
  h = DuckPrivateRunnerTest::Harness.new
  begin
    h.commit_attempts
    h.native.users.each do |user|
      context = h.runners.fetch(user).send(:context)
      forbidden = Object.new
      def forbidden.reveal(**); raise 'The UI due check read private storage'; end
      context.hidden_submissions = forbidden
      4.times do
        assert(h.game.automatic_action_due?(h.replay(user), user, context: context),
          'A pending private reveal was not scheduled')
      end
    end
    true
  ensure
    h.close
  end
end

%w[rhythm simon].each do |kind|
  check.call("#{kind}: recheck an already consulted revision, upload every page, then stop") do
    h = DuckPrivateRunnerTest::Harness.new(kind: kind, stack_entry_bytes: 1536)
    begin
      h.commit_attempts
      initial = h.replay
      [0, 1].each do |seat|
        protocol = initial.state[:round][:private]
        prepared = DuckPrivateRunnerTest::LOGIC::PrivateRound.recover(protocol, seat: seat,
          user: h.native.users[seat], vault: h.vault(h.native.users[seat]))
        assert(prepared)
        assert(prepared.envelope.payload['trace'].length > 80, 'The paging fixture is too short') if kind == 'simon'
      end
      20.times do
        break if h.replay.state[:last_resolution]
        h.native.users.each do |user|
          h.mark_revision_checked(user)
          h.tick(user)
        end
      end
      assert(h.replay.state[:last_resolution], 'A previously checked revision permanently suppressed the upload')
      assert(h.replay.state[:last_resolution][:settlement])
      count = h.native.events('Alice').length
      8.times { h.native.users.each { |user| h.tick(user) } }
      assert_equal(count, h.native.events('Alice').length, 'An accepted reveal was uploaded again')
      true
    ensure
      h.close
    end
  end
end

check.call('one revealed player does not upload for the other, and missing local data cancels without a score') do
  h = DuckPrivateRunnerTest::Harness.new
  begin
    h.commit_attempts
    h.tick('Alice')
    assert_equal([0], h.replay.state[:round][:private][:reveals].keys)
    own_context = h.runners.fetch('Alice').send(:context)
    assert(!h.game.automatic_action_due?(h.replay, 'Alice', context: own_context),
      'The finished host tried to reveal the other human answer')
    assert(!h.game.automatic_action_due?(h.replay, 'Outsider', context: own_context))
    h.runners.fetch('Bob').instance_variable_get(:@context_template).hidden_submissions =
      HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
    h.mark_revision_checked('Bob')
    h.tick('Bob')
    assert_equal(:technical, h.replay.state[:last_resolution][:cancelled])
    assert_equal(nil, h.replay.state[:last_resolution][:settlement])
    assert_equal([18, 18], h.replay.state[:race][:racers].values.map { |racer| racer[:feathers] })
    true
  ensure
    h.close
  end
end

check.call('an observer host moderates the round without recovering another human answer') do
  h = DuckPrivateRunnerTest::Harness.new(spectator_host: true)
  begin
    h.commit_attempts
    h.vault('Watcher').define_singleton_method(:reveal) do |**|
      raise 'Observer host tried to recover a human private answer'
    end
    3.times do
      h.tick('Watcher')
      assert_equal(:revealing, h.replay.state.dig(:round, :private, :phase))
    end
    h.players.each { |user| h.tick(user) }
    assert(h.replay.state[:last_resolution][:settlement])
    h.native.assert_converged('observer host and two human private reveals')
    true
  ensure
    h.close
  end
end

%w[rhythm simon].each do |kind|
  check.call("#{kind}: actual 1536-byte native grant includes outer metadata and command UUIDs") do
    h = DuckPrivateRunnerTest::Harness.new(kind: kind, stack_entry_bytes: 1536)
    begin
      h.commit_attempts
      240.times do
        break if h.replay.state[:last_resolution]
        h.native.users.each { |user| h.mark_revision_checked(user); h.tick(user) }
      end
      resolution = h.replay.state[:last_resolution]
      assert(resolution && resolution[:settlement], "The #{kind} upload was cancelled or stalled")
      assert_equal(100, resolution[:results][0][:score]) if kind == 'rhythm'
      sizes = h.native.core.entries.map { |entry| JSON.generate(entry.fetch('packet')).bytesize }
      assert(sizes.all? { |size| size <= 1536 }, 'A native packet exceeded the actual server grant')
      if kind == 'simon'
        assert(h.calls.count { |entry| entry.dig(:selection) == 'reveal' } > 2, 'The long trace was not paged')
      end
      h.native.assert_converged("#{kind} at native 1536-byte grant")
      {packets: sizes.length, maximum_bytes: sizes.max}
    ensure
      h.close
    end
  end
end

check.call('a smaller native grant after the first accepted Simon page preserves its offset boundaries') do
  h = DuckPrivateRunnerTest::Harness.new(kind: 'simon', stack_entry_bytes: 2048, simon_levels: 20)
  begin
    h.commit_attempts
    h.tick('Alice')
    protocol = h.replay.state[:round][:private]
    accepted = Marshal.load(Marshal.dump(protocol[:pages].fetch(0)))
    assert(!accepted.empty?, 'The long fixture did not leave a partial accepted trace')
    h.native.core.stack_entry_bytes = 1536
    boundary = h.native.core.entries.length
    240.times do
      break if h.replay.state[:last_resolution]
      h.native.users.each { |user| h.tick(user) }
    end
    assert(h.replay.state[:last_resolution][:settlement], 'Repartitioning lost part of the private trace')
    h.native.core.entries.drop(boundary).each do |entry|
      assert(JSON.generate(entry.fetch('packet')).bytesize <= 1536)
    end
    h.native.assert_converged('resumed Simon after native grant change')
    {accepted_offsets: accepted.keys, accepted_lengths: accepted.values.map { |page| GameRoomDuckRacing::PrivateRound.reveal_page_size(page) }}
  ensure
    h.close
  end
end

check.call('missing durable bytes after an accepted prefix cancels without a partial score or transfer') do
  h = DuckPrivateRunnerTest::Harness.new(kind: 'simon', stack_entry_bytes: 1536)
  begin
    h.commit_attempts
    h.tick('Alice')
    private_state = h.replay.state[:round][:private]
    assert(!private_state[:pages].fetch(0).empty?, 'The fixture needs an accepted incomplete stream')
    wire_id = "duck-wire-v2:#{private_state[:commitments][0]}"
    assert(h.vault('Alice').discard(session_id: private_state[:session_id], round_id: wire_id, user: 'Alice'))
    h.mark_revision_checked('Alice')
    h.tick('Alice')
    resolution = h.replay.state[:last_resolution]
    assert_equal(:technical, resolution[:cancelled])
    assert_equal(nil, resolution[:settlement])
    assert_equal([18, 18], h.replay.state[:race][:racers].values.map { |racer| racer[:feathers] })
    assert(JSON.generate(h.native.core.entries.last['packet']).bytesize <= 1536)
    true
  ensure
    h.close
  end
end

%w[Alice Bob].each do |locked_user|
  check.call("unreadable durable trace for #{locked_user} cancels only the challenge, not the executor") do
    h = DuckPrivateRunnerTest::Harness.new(kind: 'simon', stack_entry_bytes: 1536)
    Dir.mktmpdir('duck-private-read-lock-') do |directory|
      storage = HiddenSubmissionFiles::Storage.new(HiddenSubmissionFiles.new(directory))
      storage.singleton_class.class_eval do
        attr_accessor :read_locked
        private
        define_method(:read_snapshot_file) do |path|
          raise Errno::EACCES, 'simulated private trace read lock' if read_locked
          super(path)
        end
      end
      h.runners.fetch(locked_user).instance_variable_get(:@context_template).hidden_submissions =
        HiddenSubmissions::Vault.new(storage)
      begin
        h.commit_attempts
        h.tick(locked_user)
        protocol = h.replay.state[:round][:private]
        seat = h.players.index(locked_user)
        assert(!protocol[:pages].fetch(seat).empty?, 'Expected an accepted, incomplete native trace')
        before = h.native.events('Alice').length
        status, cancellation = h.game.action_for({'kind'=>'duck', 'action'=>'cancel', 'reason'=>'technical',
          'challenge'=>h.replay.state[:round][:challenge][:id]}, h.replay(locked_user), locked_user,
          context: h.runners.fetch(locked_user).send(:context))
        assert_equal(:ok, status)
        # The native private cancellation is one accepted command batch,
        # including its envelope metadata, not necessarily one wire row.
        expected_count = before + cancellation.events.length
        storage.read_locked = true
        h.mark_revision_checked(locked_user)
        h.tick(locked_user)
        result = h.replay.state[:last_resolution]
        assert(result && result[:cancelled] == :technical, 'Unreadable trace left the challenge stuck')
        assert_equal(nil, result[:settlement], 'A read failure invented a private score')
        assert_equal([18, 18], h.replay.state[:race][:racers].values.map { |racer| racer[:feathers] })
        assert_equal(expected_count, h.native.events('Alice').length, 'Expected one technical cancellation batch')
        assert(!h.runners.fetch(locked_user).instance_variable_get(:@internal_error), 'Read fault stopped the executor')
        storage.read_locked = false
        3.times { h.native.users.each { |user| h.tick(user) } }
        assert_equal(expected_count, h.native.events('Alice').length, 'Recovery repeated the cancelled reveal')
        h.native.assert_converged('private trace read failure')
        true
      ensure
        storage.read_locked = false
        h.close
      end
    end
  end
end

check.call('one input exceeding the technical memory budget cancels without a commitment or feather transfer') do
  h = DuckPrivateRunnerTest::Harness.new(stack_entry_bytes: 1536)
  begin
    before = h.native.core.entries.length
    text = 'x' * GameRoomDuckRacing::PrivateTraceStream::MAX_EXPANDED_BYTES
    trace = {'actions' => [{'at' => 100, 'input' => {'kind' => 'answer', 'value' => text, 'press_id' => 1}}],
      'finished_at' => 100}
    h.submit('Alice', {'kind' => 'duck', 'action' => 'submit_trace',
      'challenge' => h.replay.state[:round][:challenge][:id], 'trace' => trace})
    resolution = h.replay.state[:last_resolution]
    assert_equal(:technical, resolution[:cancelled])
    assert_equal(nil, resolution[:settlement])
    assert_equal([18, 18], h.replay.state[:race][:racers].values.map { |racer| racer[:feathers] })
    assert_equal(before + 1, h.native.core.entries.length)
    assert(JSON.generate(h.native.core.entries.last['packet']).bytesize <= 1536)
    true
  ensure
    h.close
  end
end

path = File.expand_path('../../../tmp/duck-racing/private-reveal-runner.json', __dir__)
FileUtils.mkdir_p(File.dirname(path))
report = File.file?(path) ? JSON.parse(File.read(path)) : {'runs' => []}
report['runs'] << {scope: 'Local real adapter, independent human vaults and shared executor; no live account',
  cases: cases, failures: cases.count { |row| row[:status] == 'FAIL' }}
File.write(path, JSON.pretty_generate(report) + "\n")
cases.each { |row| puts "#{row[:status]} #{row[:name]}#{row[:error] ? ': ' + row[:error] : ''}" }
raise 'Duck private reveal runner regression failed' if cases.any? { |row| row[:status] == 'FAIL' }
puts "PASS #{cases.length} Duck private reveal executor scenarios"
