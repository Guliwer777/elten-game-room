require_relative '../support/room_interface'
require_relative '../support/native_room_harness'

# Exercise the ordinary waiting-room bindings and native-session writer.
# Background monitoring is covered separately; this controlled fixture keeps
# one foreground task in flight while the user presses Enter in the chat.
class WaitingRoomTransport
  def initialize(native); @native = native; end
  def live_store?; false; end
  def method_missing(name, *arguments, **options, &block)
    @native.public_send(name, *arguments, **options, &block)
  end
  def respond_to_missing?(name, include_private = false)
    @native.respond_to?(name, include_private)
  end
end

module EltenAPI::Tasks
  class Cancelled < StandardError; end unless const_defined?(:Cancelled)
  class CancellationToken
    def raise_if_cancelled!; end
    def cancel(*); end
  end
  class << self
    attr_accessor :chat_probe
    def run(**options)
      chat_probe&.call(options)
      yield nil, options[:cancellation_token] || CancellationToken.new
    end
  end
end

h = NativeRoomHarness.new(game: GameRoomGames::FourInARow.new, users: %w[Alice Bob])
sender = TableActivityRepository.new(server_tables: {}, transport: h.transports['Alice'])
recipient = TableActivityRepository.new(server_tables: {}, transport: h.transports['Bob'])
app = EltenGameRoom.allocate
app.instance_variable_set(:@lobby, LobbyRepository.allocate)
app.instance_variable_set(:@games, h.repositories['Alice'])
app.instance_variable_set(:@transport, WaitingRoomTransport.new(h.transports['Alice']))
app.instance_variable_set(:@table_activity, sender)
tracker = Object.new
tracker.define_singleton_method(:observe) { |_| [] }
app.define_singleton_method(:room_membership_tracker) { |_| tracker }
app.define_singleton_method(:play_game_sounds) { |_| }
app.define_singleton_method(:play_game_sound) { |_| }
app.define_singleton_method(:announce_new_table_activity) { |_, after_id:| after_id }
app.define_singleton_method(:announce_server_table_access) {}
app.define_singleton_method(:leave_table_from_screen) { |_| true }
app.define_singleton_method(:activate_table_transport) { |_| true }
app.define_singleton_method(:alert) { |text| raise "Unexpected alert: #{text}" }
loads = 0
app.define_singleton_method(:load_room_state) do |_row, **_options|
  loads += 1
  run_network_task('Updating table') do
    room = LobbyRepository::TableSnapshot.new(**h.transports['Alice'].room_snapshot(h.table))
    GameRoomLifecycle::State.new(room: room, game_snapshot: nil, game: h.game, replay: nil,
      activity_entries: sender.entries_for(h.table))
  end
end

first = second = false
EltenAPI::Tasks.chat_probe = lambda do |options|
  pending = options[:ui]
  next unless pending.is_a?(GameRoomUI::PendingOperation)
  layout = app.instance_variable_get(:@table_layouts).fetch(h.table['__id'])
  if options[:title] == 'Updating table' && loads > 1 && !first
    first = true
    layout.form.index = layout.form.fields.index(layout.chat)
    layout.chat.set_text('First while refreshing')
    10.times { layout.chat.trigger(:select) }
  elsif options[:title] == 'Sending chat message' && !second
    second = true
    layout.chat.set_text('Second while sending')
    10.times { layout.chat.trigger(:select) }
    layout.chat.set_text('Unsubmitted third draft')
  end
end
visits = 0
Form.driver = lambda do |form|
  visits += 1
  raise 'Waiting-room chat did not settle' if visits > 3
  layout = app.instance_variable_get(:@table_layouts).fetch(h.table['__id'])
  if visits == 1
    h.as('Bob') { recipient.append(table: h.table, kind: 'chat', message: 'Refresh trigger') }
    form.instance_variable_get(:@timers).each(&:fire)
  else
    messages = recipient.entries_for(h.table).select { |entry| entry.kind == 'chat' && entry.actor == 'Alice' }.map(&:message)
    assert(first && second, 'The fixture missed one pending operation')
    assert(messages == ['First while refreshing', 'Second while sending'], "Wrong delivered messages: #{messages.inspect}")
    assert(layout.chat.text == 'Unsubmitted third draft', 'An old acknowledgement erased the next draft')
    assert(layout.focus_location == [:chat, 0], 'Sending chat changed focus')
    layout.back_button.trigger(:press)
  end
end
h.as('Alice') { app.send(:run_table_screen, h.table) }
assert(visits == 2, 'The user had to press Enter again after the task')
puts 'PASS waiting-room chat: first Enter during refresh, bounded second message, one copy per recipient, newer draft and focus retained'
