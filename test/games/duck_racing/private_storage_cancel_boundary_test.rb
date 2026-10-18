require_relative '../../support/ui'
require_relative '../../../lib/game_surfaces'
require_relative '../../support/duck_game_adapter'
require_relative '../../support/session_runner'
require_relative '../../support/hidden_submission_files'

class DuckReadFaultStorage < HiddenSubmissionFiles::Storage
  attr_accessor :locked
  private
  def read_snapshot_file(path)
    raise Errno::EACCES, 'private compact answer is temporarily unreadable' if locked
    super
  end
end

%w[Alice Bob].each do |fault_user|
  Dir.mktmpdir('duck-compact-storage-') do |directory|
    source = DuckGameAdapterTest::Harness.new(kind: 'rock_paper_scissors')
    game = GameRoomGames::DuckRacing.new(resources: source.resources)
    native = DuckGameAdapterTest::NativeHarness.new(game: game, users: %w[Alice Bob],
      options: game.default_options.merge('challenges' => ['rock_paper_scissors'], 'bot_delay' => 0))
    native.start
    stores, vaults, runners = {}, {}, {}
    native.users.each do |user|
      path = File.join(directory, user)
      FileUtils.mkdir_p(path)
      stores[user] = DuckReadFaultStorage.new(HiddenSubmissionFiles.new(path))
      vaults[user] = HiddenSubmissions::Vault.new(stores[user])
    end
    time = 1_000_000
    send_action = lambda do |user, selection, seed = 17|
      time += 10
      native.submit_at(selection, actor: user, at: time, seed: seed, vault: vaults.fetch(user))
    end
    begin
      send_action.call('Alice', {'action' => 'start'}, source.seed_for('super_challenge'))
      card = native.replay('Alice').state[:race][:racers][0][:hand].find { |copy| copy.type == 'super_challenge' }
      send_action.call('Alice', {'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id}})
      challenge = native.replay('Alice').state[:round][:challenge]
      native.users.each do |user|
        send_action.call(user, {'action' => 'ready', 'challenge' => challenge[:id],
          'fingerprint' => source.resources.fetch(:fingerprint)})
      end
      round = native.replay('Alice').state[:round]
      assert(round[:private][:compact], 'Independent test did not enter current compact protocol')
      native.users.each_with_index do |user, seat|
        trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat,
          resources: source.resources, compact: true)
        assert(trace.submit({kind: :choose, value: seat.zero? ? 'rock' : 'scissors', press_id: 1}, at: 100))
        send_action.call(user, {'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot})
      end
      current = native.replay('Alice')
      assert(current.state[:round][:private][:phase] == :revealing, 'Both compact commitments were not accepted')
      balances = current.state[:race][:racers].transform_values { |racer| racer[:feathers] }
      positions = current.state[:race][:racers].transform_values { |racer| racer[:progress] }
      native.users.each_with_index do |user, seat|
        runner = runners[user] = runner_for(native, user)
        clock = Object.new
        clock.define_singleton_method(:now_f) { |_session| time / 1000.0 }
        runner.instance_variable_set(:@clock, clock)
        template = runner.instance_variable_get(:@context_template)
        template.hidden_submissions = vaults.fetch(user)
        template.local_data = {'duck_host' => user == 'Alice', 'duck_seat' => seat,
          'duck_stack_entry_bytes' => native.transports.fetch(user).game_action_limits(native.table)['max_stack_entry_bytes']}
      end
      tick = lambda do |user, count|
        runner = runners.fetch(user)
        count.times do
          runner.publish_view(session: native.session, replay: native.replay(user), busy: false,
            context: runner.send(:context))
          step(native, runner, user)
        end
      end
      stores.fetch(fault_user).locked = true
      tick.call(fault_user, 1)
      after = native.replay('Alice')
      assert(after.state[:last_resolution][:cancelled] == :technical, 'Read fault did not cancel the compact challenge')
      assert(after.state[:last_resolution][:settlement].nil? && after.state[:last_resolution][:results].nil?,
        'Technical cancellation invented a score or feather transfer')
      assert(after.state[:race][:racers].transform_values { |racer| racer[:feathers] } == balances, 'Cancellation changed feathers')
      assert(after.state[:race][:racers].transform_values { |racer| racer[:progress] } == positions, 'Cancellation moved racers')
      assert(!after.finished? && after.state[:round].nil?, 'Technical cancellation ended the whole race')
      snapshot = native.repositories.fetch('Alice').snapshot_for(native.session)
      assert(!snapshot.session['__aborted'] && !snapshot.session['__frozen'], 'Cancellation aborted/froze the session')
      before = native.events('Alice').length
      native.users.each { |user| tick.call(user, 20) }
      assert(native.events('Alice').length == before, 'Locked file caused repeated cancellation records')
      stores.fetch(fault_user).locked = false
      native.users.each { |user| tick.call(user, 2) }
      assert(native.events('Alice').length == before, 'Recovery republished the discarded challenge result')
      # Cleanup is checked with an accepted new view, not by polling private
      # files while an idle race revision is unchanged.
      send_action.call(after.current_player, {'action' => 'race', 'input' => {'kind' => 'roll'}})
      assert(native.events('Alice').length > before, 'The same race could not continue after technical cancellation')
      native.users.each { |user| tick.call(user, 1) }
      native.users.each do |user|
        assert(vaults.fetch(user).envelopes(session_id: native.session['__id'], user: user, round_prefix: 'duck:').empty?,
          'Confirmed technical cancellation retained the prepared answer')
      end
      native.assert_converged('current compact private storage cancellation and next roll')
    ensure
      stores.each_value { |storage| storage.locked = false }
      runners.each_value(&:close)
      native.as('Alice') { native.view('Alice')&.close }
    end
  end
end

puts 'PASS compact Duck private read failure: owner/guest cancellation once, unchanged positions/feathers, cleanup and next native roll'
