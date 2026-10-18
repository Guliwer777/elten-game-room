require_relative "../support/session_runner"
require_relative "../support/statistics_tables"
require_relative "../support/private_archives"
require_relative "../../lib/account_saved_games"
require_relative "../../lib/game_statistics_service"

module StatisticsMatchLifecycleTest
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

  def self.observe(h, services)
    services.each do |user, service|
      h.as(user) do
        repository = h.repositories.fetch(user)
        snapshot = repository.snapshot_for(h.session, force_events: true)
        replay = h.game.replay(snapshot.session, snapshot.events, repository)
        service.observe(session: snapshot.session, replay: replay, game_id: h.game.id,
          viewer: user, participants: snapshot.session.fetch("__players"))
      end
    end
  end

  def self.flush(h, services)
    services.each do |user, service|
      check(h.as(user) { service.flush }, "#{user}: confirmed lifecycle reports did not flush: #{service.last_error.inspect}")
      check(service.work_status == :idle, "#{user}: bounded fixture left queued work")
    end
  end

  game = GameRoomGames::TicTacToe.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  initial = h.session.fetch("__statistics")
  h.add_client("Watcher")
  check(h.join("Watcher"), "Observer could not join the real broker room")
  h.as("Watcher") { h.transports.fetch("Watcher").set_observer(h.table, true, actor: "Watcher") }
  now = Time.now.to_i
  day = GameRoomStatistics::Periods.today(clock: -> { Time.at(now) }).strftime("%Y%m%d").to_i
  shared = StatisticsMemoryTable.new
  storage = {}
  stores = {}
  services = %w[Alice Bob Watcher].each_with_index.to_h do |user, index|
    api = StatisticsMemoryApi.new
    api.tables["statistics_events"] = shared
    identity = api.tables.fetch("statistics_accounts")
    identity.after_upsert = ->(row) { row["__id"] = 7 + index; identity.rows.first["__id"] = 7 + index }
    storage[user] = Storage.new
    stores[user] = GameRoomStatistics::Store.new(app_uuid: "cross-module-fixture", user: user,
      api: api, client: Object.new, current_user: -> { Session.name })
    service = GameRoomStatistics::Service.new(program: storage[user], storage: storage[user], user: user,
      store: stores[user], clock: -> { now }, current_user: -> { Session.name })
    [user, service]
  end
  observe(h, services)
  check(storage.values.all? { |value| value.data.empty? } && shared.rows.empty?, "Replay callback performed storage/API I/O")
  flush(h, services)
  check(shared.rows.count { |row| row["kind"] == "started" } == 1, "Three readers counted one start several times")
  check(shared.rows.select { |row| row["kind"] == "player" }.map { |row| row["person"] }.sort == [7, 8], "Observer or duplicate participant became a player")

  2.times do
    replay = h.replay("Alice")
    h.submit(replay.current_player, game.legal_actions(replay, replay.current_player).first)
  end
  boundary = h.as("Alice") { h.transports["Alice"].freeze_game(h.session) }
  snapshot = h.repositories["Alice"].snapshot_for(h.session, force_events: true)
  saves = AccountSavedGames.new(storage["Alice"], owner: "Alice", resources: PrivateArchiveDouble.new)
  archive = saves.put(game: game, table: h.table, snapshot: snapshot, repository: h.repositories["Alice"], now: boundary.created_at)
  check(archive["statistics"] == initial, "Actual archive lost match identity/date/mode")
  h.as("Alice") { h.transports["Alice"].deactivate_table(table_id: h.table["__id"]) }
  table = h.as("Alice") do
    h.transports["Alice"].create_room(name: "Statistics lifecycle restoration", game: game.id,
      owner: "Alice", game_options: archive["options"], resume_save_id: archive["id"])
  end
  h.instance_variable_set(:@table, table)
  check(h.join("Bob") && h.join("Watcher"), "Restored room could not be joined")
  restored = saves.restored_data(archive, game: game, table_id: table["__id"], now: boundary.created_at)
  session = h.as("Alice") do
    h.repositories["Alice"].restore_session(table: table, game: game.id,
      players: restored[:players], options: archive["options"], restore: restored)
  end
  h.instance_variable_set(:@session, session)
  check(session["__statistics"] == initial && h.replay("Bob").accepted_events.length == 2,
    "Restoration fabricated a new match or lost accepted moves")
  observe(h, services)
  flush(h, services)
  check(shared.rows.count { |row| row["kind"] == "started" } == 1, "Restoration counted a second start")
  h.as("Alice") do
    view = h.view("Alice")
    view.transfer_ownership(view.participants.find { |participant| participant.user == "Bob" })
  end
  successor = runner_for(h, "Bob", covered: -> { false })
  step(h, successor, "Bob", count: 3)
  h.instance_variable_set(:@session, h.repositories["Bob"].snapshot_for(h.session).session)
  observe(h, services)
  flush(h, services)
  check(shared.rows.count { |row| row["kind"] == "started" } == 1, "Host handover counted a second start")
  10.times do
    replay = h.replay("Bob")
    break if replay.finished?
    h.submit(replay.current_player, game.legal_actions(replay, replay.current_player).first)
  end
  finished = h.replay("Bob")
  check(finished.finished?, "The restored game did not actually finish")
  h.write("Bob", [GameRoomGames::EventCommand.new(action: "place", value: "99,99")])
  check(h.events("Bob").length > h.replay("Bob").accepted_events.length, "Rejected late-event fixture did not reach public history")
  observe(h, services)
  shared.lose_ack = true
  check(!h.as("Alice") { services["Alice"].flush }, "Lost native insert ACK was reported as confirmed")
  check(services["Alice"].last_error.is_a?(IOError), "Lost ACK was not retryable")
  check(shared.rows.count { |row| row["kind"] == "completed" } == 1, "Lost ACK did not leave exactly one committed completion")
  flush(h, services)
  check(shared.rows.count { |row| row["kind"] == "completed" } == 1, "Retry/other readers duplicated the completion")
  old_count = shared.rows.length
  now += 86_400
  observe(h, services)
  flush(h, services)
  check(shared.rows.length == old_count, "Viewing yesterday's finish manufactured a player-day or another completion")

  current_table = h.transports["Bob"].room_snapshot(h.table).fetch(:table)
  rematch = h.as("Bob") do
    h.repositories["Bob"].start_session(table: current_table, game: game.id,
      players: %w[Alice Bob], options: JSON.generate(game.default_options))
  end
  h.instance_variable_set(:@session, rematch)
  check(rematch.dig("__statistics", "id") != initial["id"], "Real rematch reused an old statistical identity")
  observe(h, services)
  flush(h, services)
  h.as("Bob") { h.transports["Bob"].abort_game(rematch) }
  observe(h, services)
  flush(h, services)
  report = h.as("Alice") { stores["Alice"].report(Struct.new(:from_day, :to_day).new(nil, day)) }
  check(report.values_at("started", "completed", "players") == [2, 1, 2], "Rematch/technical abort changed lifecycle totals")
  check(shared.rows.select { |row| %w[started completed].include?(row["kind"]) }.all? { |row| row["mode"] == "humans" }, "Handover/observer changed the initial mode")
  puts "PASS statistics lifecycle across native broker, replay, archive, host handover, queue, unknown ACK and Store: #{@checks} checks"
ensure
  successor&.close
  services&.each_value(&:close)
end
