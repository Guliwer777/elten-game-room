require_relative '../support/settings_widget'
require_relative '../support/session_runner'
require_relative '../support/statistics_tables'

# Independently exercise the original host leaving and returning, rather than
# changing an eliminated flag in a synthetic replay. The clock below belongs
# only to local statistics services; neither native game time nor event times
# are altered.
module EliminatedHostDailyBoundary
  class Storage
    attr_reader :data
    def initialize; @data = {}; end
    def read_json(path, default:); JSON.parse(JSON.generate(@data.fetch(path, default))); end
    def update_json(path, default:)
      value = read_json(path, default: default)
      yield value
      @data[path] = JSON.parse(JSON.generate(value))
    end
  end

  def self.check(value, message)
    @checks = @checks.to_i + 1
    raise message unless value
  end

  def self.telemetry(user, clock)
    api, storage = StatisticsMemoryApi.new, Storage.new
    store = GameRoomStatistics::Store.new(app_uuid: 'independent-host-player-day', user: user,
      api: api, client: Object.new, current_user: -> { Session.name })
    service = GameRoomStatistics::Service.new(program: storage, storage: storage, user: user,
      store: store, current_user: -> { Session.name }, clock: clock)
    [service, api, storage]
  end

  game = GameRoomGames::Categories.new
  options = game.normalize_options(game.default_options.merge('round_time' => 0,
    'category_set' => 'custom', 'custom_categories' => %w[country city],
    'round_category_count' => 2, 'target_score' => 100, 'judge_mode' => 'master'))
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol], options: options)
  h.start
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    now: Time.now.to_i, table_owner: 'Alice', random_source: GameRoomRandom::LocalSecureSource.new,
    hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))
  h.submit('Alice', context: context)
  now = Time.now.to_i
  first_day = GameRoomStatistics::Periods.today(clock: -> { Time.at(now) }).strftime('%Y%m%d').to_i
  alice_service, alice_api, alice_storage = telemetry('Alice', -> { now })
  bob_service, bob_api, = telemetry('Bob', -> { now })
  app = EltenGameRoom.new
  alice_observer = app.send(:statistics_observer_for, game, service: alice_service, viewer: 'aLiCe')
  bob_observer = app.send(:statistics_observer_for, game, service: bob_service, viewer: 'Bob')
  rows = ->(api) { api.tables.fetch('statistics_events').rows }
  observe = lambda do |user, callback, service|
    h.as(user) do
      snapshot = h.repositories.fetch(user).snapshot_for(h.session, force_events: true)
      replay = game.replay(snapshot.session, snapshot.events, h.repositories.fetch(user))
      before = Marshal.dump([snapshot.session, replay.state])
      callback.call(snapshot.session, replay)
      check(Marshal.dump([snapshot.session, replay.state]) == before, 'Statistics changed native roster/replay')
      check(service.flush, "Statistics failed for #{user}: #{service.last_error.inspect}")
      [snapshot, replay]
    end
  end
  first_snapshot, = observe.call('Alice', alice_observer, alice_service)
  original_match = first_snapshot.session.fetch('__statistics').fetch('id')
  original_players = first_snapshot.session.fetch('__players').dup
  check(rows.call(alice_api).count { |row| row['kind'] == 'player' } == 1, 'Original host did not participate')

  h.as('Alice') do
    LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Alice')), transport: h.transports.fetch('Alice'),
      server_tables: Object.new).leave_table(h.table, 'Alice')
  end
  successor = runner_for(h, 'Bob', covered: -> { false })
  step(h, successor, 'Bob', count: 3)
  check(h.transports.fetch('Bob').room_snapshot(h.table).fetch(:table).fetch('owner') == 'Bob',
    'Native ownership did not pass to Bob')
  check(h.join('Alice'), 'Former host could not return through ordinary native membership')
  step(h, successor, 'Bob', count: 3)
  now += 86_400
  restored_snapshot, restored_replay = observe.call('Alice', alice_observer, alice_service)
  check(game.eliminated_from_game?(restored_replay, 'Alice'), 'Departure did not permanently remove the host')
  check(restored_snapshot.session['__players'] == original_players, 'Original match slots were rewritten')
  check(restored_snapshot.session.dig('__statistics', 'id') == original_match, 'Host transfer changed match identity')
  check(!restored_replay.finished? && !restored_snapshot.session['__aborted'], 'Departure fabricated a terminal match')
  check(rows.call(alice_api).select { |row| row['kind'] == 'player' }.map { |row| row['day_key'] } == [first_day],
    'Returning eliminated host was counted as an active player on another day')
  observe.call('Bob', bob_observer, bob_service)
  check(rows.call(bob_api).count { |row| row['kind'] == 'player' } == 1,
    'Surviving new host was incorrectly excluded from daily participation')
  check(rows.call(alice_api).count { |row| row['kind'] == 'started' } == 1 &&
    rows.call(alice_api).none? { |row| row['kind'] == 'completed' }, 'Removal changed lifecycle events')

  # A newly constructed service and callback must not rely on a previous
  # service's daily de-duplication cache to avoid counting the spectator.
  cold_service, cold_api, cold_storage = telemetry('Alice', -> { now })
  cold_observer = app.send(:statistics_observer_for, game, service: cold_service, viewer: 'Alice')
  snapshot_before = Marshal.dump([restored_snapshot.session, restored_replay.state])
  h.as('Alice') { cold_observer.call(restored_snapshot.session, restored_replay) }
  check(cold_api.calls.empty? && cold_storage.data.empty?, 'UI callback performed storage or network I/O')
  h.as('Alice') { check(cold_service.flush, 'Cold statistics flush failed') }
  check(rows.call(cold_api).none? { |row| row['kind'] == 'player' }, 'Cold observer counted the eliminated host')
  check(rows.call(cold_api).count { |row| row['kind'] == 'started' } == 1, 'Cold observer lost original start')
  check(Marshal.dump([restored_snapshot.session, restored_replay.state]) == snapshot_before,
    'Cold observer mutated the accepted state')

  # Account changes are not evidence of game participation and cannot send a
  # stale callback's staged records as the new account.
  now += 86_400
  old_rows = rows.call(alice_api).map(&:dup)
  h.as('Bob') do
    alice_observer.call(restored_snapshot.session, restored_replay)
    check(!alice_service.flush, 'A stale-account service uploaded data')
  end
  check(rows.call(alice_api) == old_rows, 'Account switch changed the previous account statistics')
  h.as('Alice') { check(alice_service.flush, 'Original account could not recover after returning') }
  check(rows.call(alice_api) == old_rows, 'Recovery manufactured a player-day')
  puts "PASS independent eliminated-host daily boundary: #{@checks} checks"
ensure
  successor&.close
  [alice_service, bob_service, cold_service].compact.each(&:close)
end
