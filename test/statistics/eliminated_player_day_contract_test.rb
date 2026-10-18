require_relative '../support/settings_widget'
require_relative '../support/session_runner'
require_relative '../support/statistics_tables'

module StatisticsPlayerDayContract
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

  def self.service(clock, current_user: -> { 'Bob' })
    api, storage = StatisticsMemoryApi.new, Storage.new
    store = GameRoomStatistics::Store.new(app_uuid: 'player-day-contract', user: 'Bob',
      api: api, client: Object.new, current_user: current_user)
    service = GameRoomStatistics::Service.new(program: storage, storage: storage, user: 'Bob',
      store: store, clock: clock, current_user: current_user)
    [service, api, storage]
  end

  # A real native departure is reduced before returning as an observer. The
  # immutable match slots intentionally retain Bob; they are not daily activity.
  game = GameRoomGames::Categories.new
  options = game.normalize_options(game.default_options.merge('round_time' => 0,
    'category_set' => 'custom', 'custom_categories' => %w[country city],
    'round_category_count' => 2, 'target_score' => 100, 'judge_mode' => 'rotating'))
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol], options: options)
  h.start
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    now: Time.now.to_i, table_owner: 'Alice', random_source: GameRoomRandom::LocalSecureSource.new,
    hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))
  h.submit('Alice', context: context)
  now = Time.now.to_i
  service, api, storage = service(-> { now }, current_user: -> { Session.name })
  observer = EltenGameRoom.new.send(:statistics_observer_for, game, service: service, viewer: 'Bob')
  check(observer.respond_to?(:call), 'Actual application did not provide the observer')
  read = lambda do
    snapshot = h.repositories.fetch('Alice').snapshot_for(h.session, force_events: true)
    replay = game.replay(snapshot.session, snapshot.events, h.repositories.fetch('Alice'))
    [snapshot, replay]
  end
  observe = lambda do
    snapshot, replay = read.call
    original = Marshal.dump([snapshot.session, replay.state])
    h.as('Bob') { observer.call(snapshot.session, replay) }
    check(Marshal.dump([snapshot.session, replay.state]) == original, 'Statistics modified the match or original roster')
    h.as('Bob') { check(service.flush, "Statistics failed: #{service.last_error.inspect}") }
  end
  observe.call
  check(api.tables.fetch('statistics_events').rows.count { |row| row['kind'] == 'player' } == 1,
    'Initial active participation was lost')
  now += 86_400
  observe.call
  check(api.tables.fetch('statistics_events').rows.count { |row| row['kind'] == 'player' } == 2,
    'An active match crossing midnight did not record the new day')
  h.as('Bob') do
    LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Bob')), transport: h.transports.fetch('Bob'),
      server_tables: Object.new).leave_table(h.table, 'Bob')
  end
  runner = runner_for(h, 'Alice', covered: -> { false })
  step(h, runner, 'Alice', count: 3)
  check(h.join('Bob'), 'Departed native account could not return')
  step(h, runner, 'Alice', count: 3)
  snapshot, replay = read.call
  check(game.eliminated_from_game?(replay, 'Bob') && replay.state[:departed_players] == ['Bob'],
    'Native departure was not actually reduced')
  check(!replay.finished? && !snapshot.session['__aborted'] && snapshot.session['__players'].include?('Bob'),
    'The fixture must retain original seats while other players continue')
  now += 86_400
  observe.call
  rows = api.tables.fetch('statistics_events').rows
  check(rows.count { |row| row['kind'] == 'player' } == 2,
    'A permanently removed player returning only to watch manufactured a later player-day')
  check(rows.count { |row| row['kind'] == 'started' } == 1 && rows.none? { |row| row['kind'] == 'completed' },
    'Elimination changed lifecycle counting')

  runner.close
  h.start
  snapshot, replay = read.call
  check(!game.eliminated_from_game?(replay, 'Bob'), 'Fresh match retained old elimination')
  observe.call
  rows = api.tables.fetch('statistics_events').rows
  check(rows.count { |row| row['kind'] == 'player' } == 3 && rows.count { |row| row['kind'] == 'started' } == 2,
    'Return as a genuine player in a new match did not resume daily participation')
  service.close

  # These are explicit projection-boundary cases, not claims of full games.
  # Use each real game's permanent-removal contract, including its false cases.
  cases = [
    [GameRoomGames::Uno.new, {eliminated: {'Bob' => true}}, false, 'UNO eliminated'],
    [GameRoomGames::Uno.new, {eliminated: {}}, true, 'UNO next hand'],
    [GameRoomGames::NinetyNine.new, {eliminated: {'Bob' => true}}, false, '99 eliminated'],
    [GameRoomGames::NinetyNine.new, {eliminated: {}}, true, '99 inactive connection is not elimination'],
    [GameRoomGames::Monopoly.new, {bankrupt: {'Bob' => true}}, false, 'Monopoly bankrupt'],
    [GameRoomGames::Monopoly.new, {bankrupt: {}}, true, 'Monopoly hidden window is not elimination'],
    [GameRoomGames::Rummy.new, {eliminated: {'Bob' => true}}, false, 'Rummy eliminated'],
    [GameRoomGames::War.new, {players: %w[Alice Bob], phase: :playing, eliminated: {'Bob' => true}}, false, 'War eliminated'],
    [GameRoomGames::War.new, {players: %w[Alice Bob], phase: :awaiting_deal, eliminated: {'Bob' => true}}, true, 'War new deal'],
    [GameRoomGames::ScientificWar.new, {players: %w[Alice Bob], eliminated: {'Bob' => true}}, false, 'Scientific War eliminated'],
    [GameRoomGames::Domino.new, {units: {0 => ['Alice'], 1 => ['Bob']}, eliminated: {1 => true}}, false, 'Domino eliminated unit'],
    [GameRoomGames::Poker.new, {players: %w[Alice Bob], stacks: {'Bob' => 0}, phase: :hand_complete}, false, 'Poker empty stack after hand'],
    [GameRoomGames::Poker.new, {players: %w[Alice Bob], stacks: {'Bob' => 0}, hands: {'Bob' => [1]}, phase: :betting}, true, 'Poker all-in'],
    [GameRoomGames::Poker.new, {players: %w[Alice Bob], stacks: {'Bob' => 10}, folded: {'Bob' => true}, phase: :betting}, true, 'Poker folded only'],
    [GameRoomGames::TicTacToe.new, nil, true, 'Ordinary board game']
  ]
  cases.each do |definition, state, eligible, label|
    [false, true].each do |finished|
      now = Time.now.to_i
      service, api, storage = service(-> { now })
      session = {'__players' => %w[Alice Bob], '__statistics' =>
        {'id' => SecureRandom.uuid, 'mode' => 'humans', 'started_at' => now - 86_400}}
      replay = GameRoomGames::Replay.new(players: %w[Alice Bob], state: state,
        winner: finished ? 'Alice' : nil, accepted_events: [{'created_at' => now}])
      observer = EltenGameRoom.new.send(:statistics_observer_for, definition, service: service, viewer: 'bOb')
      original = Marshal.dump([session, state])
      observer.call(session, replay)
      check(api.calls.empty? && storage.data.empty?, "#{label}: UI callback performed I/O")
      check(Marshal.dump([session, state]) == original, "#{label}: callback changed source data")
      check(service.flush, "#{label}: telemetry failed: #{service.last_error.inspect}")
      rows = api.tables.fetch('statistics_events').rows
      check(rows.count { |row| row['kind'] == 'player' } == (eligible ? 1 : 0), "#{label}: wrong daily eligibility")
      check(rows.count { |row| row['kind'] == 'started' } == 1, "#{label}: lost start")
      check(rows.count { |row| row['kind'] == 'completed' } == (finished ? 1 : 0), "#{label}: altered completion")
      check(rows.all? { |row| row['mode'] == 'humans' }, "#{label}: original mode changed")
      service.close
    end
  end
  puts "PASS statistics actual native departed return and game elimination eligibility: #{@checks} checks"
ensure
  runner&.close
  service&.close
end
