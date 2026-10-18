require_relative "../support/room_interface"
require_relative "../support/krowa"
require_relative "../../games/krowa_support/client"

class LifecycleClient
  attr_reader :binding, :starts, :closes
  def initialize(start_result: true); @start_result, @starts, @closes = start_result, 0, 0; end
  def bind_screen(**binding); @binding = binding; end
  def start; @starts += 1; @start_result; end
  def close; @closes += 1; end
  def before_wait(*); end
  def after_events(*, **); end
  def context_data; {}; end
end

class LifecycleSync
  def waiting?; false; end
  def recovery_pending?; false; end
  def reconciled?; false; end
  def request_recovery!(**); end
  def synchronize(**); yield; end
  def update_session(*, **); self; end
  def synchronized!; self; end
end

def lifecycle_screen(game, program, unavailable_snapshot: false, services: {})
  repo = InterfaceGameRepository.new
  gate = GameRoomBots::TurnController.new
  repo.define_singleton_method(:bot_turn_controller) { |_id| gate }
  repo.define_singleton_method(:session_by_id) { |id, table:| {'__id' => id, 'options' => '{}'} }
  repo.define_singleton_method(:session_for_table) { |table, force: false| {'__id' => 2, 'options' => '{}'} if table['__id'] == 7 }
  repo.define_singleton_method(:snapshot_for) { |current, **| GameRepository::GameSnapshot.new(session: current, events: []) }
  repo.define_singleton_method(:confirmed_event_ids) { |_| [] }
  repo.define_singleton_method(:events_revision) { |_| [0, 0] }
  table = {'__id' => 7, 'owner' => 'Alice', 'game' => game.id, 'status' => 'playing'}
  room = LobbyRepository::TableSnapshot.new(table: table, members: %w[Alice Bob], bots: [])
  screen = GameScreen.new(program: program, repository: repo, game: game,
    session: {'__id' => 1, 'options' => '{}'}, table: table, table_owner: 'Alice',
    room_snapshot_provider: -> { room }, synchronizer: LifecycleSync.new, game_services: services)
  screen.define_singleton_method(:network_task) do |_title, **_options, &operation|
    unavailable_snapshot ? nil : operation.call
  end
  screen.define_singleton_method(:synchronized_network_task) { |_title, **_options, &operation| operation.call }
  screen.define_singleton_method(:synchronize_table_status) { |_| }
  screen.define_singleton_method(:process_new_events) { |*, **| }
  screen.define_singleton_method(:process_new_table_activity) { |_| }
  screen.define_singleton_method(:stop_pending_speech) {}
  screen.define_singleton_method(:activity_entries_for) { |_| [] }
  screen.define_singleton_method(:perform_automatic_action) { |_| false }
  screen.define_singleton_method(:wait_for_action) do |*, **|
    if @session['__id'] == 1
      @new_session_id = 2
      :new_session
    else
      :back
    end
  end
  screen
end

# Exercise both real run-loop branches, not only the private switch helper.
# A failed client start must exit through ensure rather than open a dead game.
original_wait = GameScreen.method(:wait_for_connection)
begin
  [[false, false, true], [false, true, false], [true, true, false],
   [false, true, true], [true, true, true]].each do |unavailable, first_ok, second_ok|
    wait_calls = 0
    GameScreen.define_singleton_method(:wait_for_connection) do |*, **|
      wait_calls += 1
      raise 'continued waiting after a failed client start' if wait_calls > 1 && !second_ok
      GameRoomSync::Event.new(kind: :game_started, session_id: 2) if wait_calls == 1
    end
    clients = []
    game = GameRoomGames::FourInARow.new
    service = Object.new
    game.define_singleton_method(:build_client) do |_program, **services|
      assert(services[:test_service].equal?(service), 'rematch lost the injected services')
      assert(clients.empty? || clients.last.closes == 1, 'new client built before previous client closed')
      client = LifecycleClient.new(start_result: clients.empty? ? first_ok : second_ok)
      clients << client
      client
    end
    screen = lifecycle_screen(game, Program.new, unavailable_snapshot: unavailable, services: {test_service: service})
    assert(screen.run == :back, 'startup failure did not return safely')
    assert(clients.length == (first_ok ? 2 : 1), 'wrong number of session clients')
    clients.each_with_index do |client, index|
      assert(client.starts == 1 && client.closes == 1, 'client not started/closed exactly once')
      assert(client.binding[:session_id] == index + 1 && client.binding[:table_id] == 7, 'client bound to stale session/room')
      assert(client.binding[:owner] == 'Alice' && client.binding[:viewer] == 'Alice', 'wrong owner/viewer binding')
    end
  end
ensure
  GameScreen.define_singleton_method(:wait_for_connection, original_wait)
end
puts 'PASS client lifecycle: initial start, both new-session run paths, failed starts, binding, services and cleanup'

# Four in a Row (state=nil) has no client at all. Its existing rematch/board
# path must remain valid; the helper must not impose a realtime dependency.
assert(lifecycle_screen(GameRoomGames::FourInARow.new, Program.new).run == :back, 'clientless board game failed')

# Krowa is the other production client. New instances reload saved local data,
# while per-match private reveal and dialog deduplication do not leak forward.
run = KrowaTestGame.new
game, program = run.game, run.program
tables = Object.new
screen = lifecycle_screen(game, program, services: {server_tables: tables})
assert(screen.send(:start_game_client), 'Krowa initial client failed')
old = screen.instance_variable_get(:@game_client)
assert(old.instance_variable_get(:@server_tables).equal?(tables), 'Krowa lost injected server tables')
profile = old.instance_variable_get(:@profile)
profile.data['dictionary'] << 'wlasne'
profile.data['gallery']['kot'] = {'attempts' => 2, 'at' => 123}
program.write_json(profile.instance_variable_get(:@path), profile.data)
old.instance_variable_get(:@shown_words)['kot'] = true
old.instance_variable_get(:@private_reveal).instance_variable_set(:@word, 'kot')
screen.instance_variable_set(:@new_session_id, 2)
assert(screen.send(:switch_to_new_session), 'Krowa rematch client failed')
fresh = screen.instance_variable_get(:@game_client)
assert(!fresh.equal?(old) && fresh.context_data['dictionary'].include?('wlasne'), 'Krowa lost the saved dictionary')
assert(fresh.instance_variable_get(:@profile).data['gallery']['kot']['attempts'] == 2, 'Krowa lost the gallery')
assert(fresh.instance_variable_get(:@shown_words).empty? && fresh.instance_variable_get(:@private_reveal).word.nil?, 'Krowa kept previous match secrets/dialog state')
fresh.close
puts 'PASS other clients: clientless board game and real Krowa services/profile across rematches'
