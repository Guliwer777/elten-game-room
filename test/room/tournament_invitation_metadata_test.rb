# encoding: UTF-8
require_relative '../support/invitation_fresh_endpoint'

broker = NativeLiveSessionsBroker.new
gateway = DurableNoticeGateway.new
app = InvitationAppDriver.new(broker, 'Alice', gateway)
$game_room_test_user = 'Alice'
name = 'Alice — Bob / 1 [c9ae9b6f4805]'
marker = {
  'publication_ref'=>{'author'=>'alice', 'publication_key'=>'invitation-text-test'},
  'schedule_id'=>'a' * 64, 'match_id'=>'b' * 64, 'leg'=>1
}
table = app.transport.create_room(name: name, game: 'uno', owner: 'Alice',
  game_options: '{"score_limit":500}', tournament_match: marker)
original = Marshal.load(Marshal.dump(table))

[false, true].each_with_index do |continuation, index|
  recipient = index.zero? ? 'Bob' : 'Carol'
  result = app.send(:deliver_table_invitation, table, recipient, continuation: continuation)
  assert(result.created?, 'Tournament table invitation was not sent')
  type, metadata, ttl = app.sent.last
  assert(type == 'game_room.invitation' && ttl == 300, 'Changed ordinary invitation type or lifetime')
  assert(metadata['tournament_match'] == true, 'Tournament presentation marker is missing')
  assert((metadata['continuation'] == true) == continuation, 'Continuation flag changed')
  assert(metadata['table_id'] == table['__id'] && metadata['live_session_id'] == table['__live_session_id'], 'Entry identity changed')
  assert(metadata['table_name'] == name, 'Technical table identity was renamed')
  assert(metadata.dig('variant', 'options', 'score_limit') == 500, 'Game variant was lost')
end
assert(table == original, 'Formatting mutated the table')

ordinary = app.transport.create_room(name: name, game: 'uno', owner: 'Alice', game_options: '{}')
assert(app.send(:deliver_table_invitation, ordinary, 'Dave').created?, 'Ordinary invitation failed')
assert(!app.sent.last[1].key?('tournament_match'), 'Table name was mistaken for tournament authority')
puts 'PASS tournament invitation display marker; ordinary type, identity, variants and five-minute lifetime preserved'
