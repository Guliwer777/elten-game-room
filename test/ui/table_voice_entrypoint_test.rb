require_relative '../support/room_interface'
require_relative '../../lib/table_voice_screen'

# Load the real Program class and exercise its explicit-receiver entry point.
# The Conference device/network boundary is replaced; no keyboard is driven.
assert(EltenGameRoom.public_method_defined?(:show_table_voice),
  'GameScreen cannot call the private table-conference entry point')
assert(EltenGameRoom.private_method_defined?(:waiting_computer_context),
  'Exposing one entry point accidentally made adjacent helpers public')

class VoiceEntrySync
  def waiting?; false; end
  def recovery_pending?; false; end
  def synchronize(**); yield; end
end

program = EltenGameRoom.allocate
transport = Object.new
program.instance_variable_set(:@transport, transport)
table = {'__id'=>7, 'owner'=>'Alice', 'game'=>'four_in_a_row', 'status'=>'playing'}
calls = []
factory = GameRoomTableVoiceScreen.method(:new)
begin
  GameRoomTableVoiceScreen.define_singleton_method(:new) do |**arguments|
    Object.new.tap do |controller|
      controller.define_singleton_method(:run) { calls << arguments; true }
    end
  end

  # The waiting-table path and the active game use the same public method.
  program.public_send(:show_table_voice, table)
  repository = InterfaceGameRepository.new
  repository.define_singleton_method(:events_revision) { |_| [0, 0] }
  game = GameRoomGames::FourInARow.new
  session = {'__id'=>1, 'options'=>'{}'}
  room = LobbyRepository::TableSnapshot.new(table:table, members:%w[Alice Bob], bots:[])
  snapshot = GameRepository::GameSnapshot.new(session:session, events:[])
  configuration_calls = []
  configuration_refreshes = []
  screen = GameScreen.new(program:program, repository:repository, game:game,
    session:session, table:table, table_owner:'Alice',
    edit_options:->(value) { configuration_calls << [:options,value] },
    manage_teams:->(value) { configuration_calls << [:teams,value] },
    room_snapshot_provider:-> { room }, synchronizer:VoiceEntrySync.new)
  screen.define_singleton_method(:fetch_game_payload) do
    if configuration_calls.size > configuration_refreshes.size
      configuration_refreshes << [@room_snapshot.nil?, @activity_entries.nil?]
    end
    [snapshot, room, []]
  end
  screen.define_singleton_method(:start_game_client) { true }
  screen.define_singleton_method(:start_sound_output) {}
  screen.define_singleton_method(:start_session_runner) {}
  screen.define_singleton_method(:present_session_membership) { |_| }
  screen.define_singleton_method(:synchronize_table_status) { |_| }
  screen.define_singleton_method(:process_new_events) { |*, **| }
  screen.define_singleton_method(:process_new_table_activity) { |_| }
  screen.define_singleton_method(:perform_automatic_action) { |_| false }
  screen.define_singleton_method(:stop_pending_speech) {}
  actions = [:voice, :edit_options, :edit_teams, :back]
  screen.define_singleton_method(:wait_for_action) do |*, **|
    raise 'Unexpected extra wait' if actions.empty?
    actions.shift
  end
  assert(screen.run == :back, 'Conference action did not return to the game')
  assert(calls.size == 2 && calls.all? { |value| value == {program:program, transport:transport, table:table} },
    'Waiting and active tables did not use the same conference controller')
  assert(screen.instance_variable_get(:@suppress_surface_focus), 'Returning from Conference reset table focus')
  assert(configuration_calls == [[:options,table],[:teams,table]],
    'Shared configuration dispatch chose a different callback or table')
  assert(configuration_refreshes == [[true,true],[true,true]],
    'Configuration changes retained the previous room/activity projection')
ensure
  GameRoomTableVoiceScreen.define_singleton_method(:new, factory)
end
puts 'PASS shared table Conference entry point: real Program visibility, active GameScreen dispatch and return; no server or keyboard'
