require_relative '../support/native_room_harness'
require_relative '../../games/duck_racing_support/wire_budget'

include GameRoomTest::Assertions
codec = GameRoomEventProtocol
uuid = GameRoomDuckRacing::WireBudget::UUID
actor = 'Łucja長鴨'
h = NativeRoomHarness.new(users: [actor, 'Bob'])
h.start
repo = h.repositories.fetch(actor)
snapshot = repo.snapshot_for(h.session)
epoch = snapshot.session.fetch('__control_epoch')
sequence = 987_654
commands = [GameRoomGames::EventCommand.new(action: 'move', value: 'ąęść長鴨')]
written = h.as(actor) do
  repo.append_events(session: snapshot.session, sequence: sequence, events: commands, actor: actor)
end
packet = h.core.entries.last.fetch('packet')
wire_commands = commands.map.with_index do |command, index|
  {'action' => command.action, 'value' => command.value,
    'move_id' => packet.fetch('data').fetch('events').fetch(index).fetch('move_id')}
end
# The exact original Writer construction (including key order and JSON
# normalization), not a comparison between two calls of the new helper.
original = {'version' => 2, 'kind' => 'game_action', 'actor' => actor.to_s,
  'data' => JSON.parse(JSON.generate({'session_id' => h.session.fetch('__id'), 'sequence' => sequence,
    'controller' => false, 'control_epoch' => epoch, 'events' => wire_commands}))}
assert_equal(JSON.generate(original), JSON.generate(packet), 'Ordinary Writer packet bytes changed')
assert_equal(JSON.generate(original), JSON.generate(codec.game_action_packet(
  session_id: h.session.fetch('__id'), sequence: sequence, control_epoch: epoch,
  events: wire_commands, actor: actor)))
assert_equal(1, written.length)
assert_equal(36, wire_commands.first['move_id'].bytesize)

# Native grants are read from the active local Session, without a read/push/
# discovery request and without exposing mutable native metadata to callers.
h.core.stack_entry_bytes = 1536
before = h.view(actor).calls.dup
limits = h.transports.fetch(actor).game_action_limits(h.table)
assert_equal(1536, limits.fetch('max_stack_entry_bytes'))
limits['max_stack_entry_bytes'] = 1
assert_equal(1536, h.transports.fetch(actor).game_action_limits(h.table)['max_stack_entry_bytes'])
assert_equal(before, h.view(actor).calls)
assert_equal({}, h.transports.fetch(actor).game_action_limits(999_999))

# Find an exact native boundary using legal legacy fields. Unicode actors
# and values, long sequences, epochs and all per-command UUIDs are counted.
boundary = nil
(1..20).each do |count|
  (1..32).each do |length|
    (1..64).each do |last_length|
      candidate = Array.new(count) { {'action' => 'duck_racing', 'value' => 'ą' * length, 'move_id' => uuid} }
      candidate[-1]['value'] = 'a' * last_length
      built = codec.game_action_packet(session_id: h.session.fetch('__id'), sequence: sequence + 1,
        control_epoch: epoch, actor: actor, events: candidate)
      if JSON.generate(built).bytesize == 1536
        boundary = candidate
        break
      end
    end
    break if boundary
  end
  break if boundary
end
assert(boundary, 'Could not construct the exact 1536-byte fixture')
assert(codec.valid_wire_commands?(boundary))
records = h.core.entries.length
h.as(actor) do
  repo.append_events(session: snapshot.session, sequence: sequence + 1, events: boundary, actor: actor)
end
assert_equal(records + 1, h.core.entries.length)
assert_equal(1536, JSON.generate(h.core.entries.last.fetch('packet')).bytesize)
oversized = Marshal.load(Marshal.dump(boundary))
oversized[-1]['action'] += 'x'
assert_raises(EltenAPI::LiveSessions::StackPacketTooLarge) do
  h.as(actor) do
    repo.append_events(session: snapshot.session, sequence: sequence + 1, events: oversized, actor: actor)
  end
end
assert_equal(records + 1, h.core.entries.length)

# A Duck revision is compressed in the nested payload; unlike the legacy
# character limits, the final packet size also includes its native metadata.
replay = GameRoomGames::Replay.new(accepted_events: [{'sequence' => sequence}],
  state: {session_id: h.session.fetch('__id'), bot_controller_epoch: 'f' * 64})
data = {'action' => 'cancel', 'challenge' => 1234567, 'reason' => 'technical',
  'revision' => 123456789, 'session' => h.session.fetch('__id'), 'at' => 1791674690000}
plan = GameRoomDuckRacing::WireBudget.plan('duck_racing', data, replay: replay, actor: actor, limit: 1536)
encoded = codec.game_action_packet(session_id: replay.state[:session_id], sequence: sequence + 1,
  control_epoch: replay.state[:bot_controller_epoch], actor: actor,
  events: plan.events.map { |command| codec.normalized(command).merge('move_id' => uuid) })
bytes = JSON.generate(encoded).bytesize
assert(bytes <= 1536)
assert(GameRoomDuckRacing::WireBudget.plan('duck_racing', data, replay: replay, actor: actor, limit: bytes))
assert_raises(ArgumentError) do
  GameRoomDuckRacing::WireBudget.plan('duck_racing', data, replay: replay, actor: actor, limit: bytes - 1)
end
assert_raises(ArgumentError) do
  GameRoomDuckRacing::WireBudget.plan('duck_racing', data, replay: replay, actor: actor, limit: nil)
end
h.as(actor) { h.view(actor).close }
assert_equal({}, h.transports.fetch(actor).game_action_limits(h.table))
puts 'PASS native packet parity, cached actual limits, UTF-8/UUID/epoch/revision accounting and exact 1536/1537-byte boundary'
