require_relative '../support/host_source'
require_relative '../../lib/invitation_notifications'
require 'json'

# Use the actual host envelope: it validates the outer metadata Hash, but
# deliberately retains its nested JSON values without application coercion.
sdk = EltenTestHost.file('src/eapi/program.rb')
lines = File.readlines(sdk)
first = lines.index { |line| line.start_with?('  class AppNotification') }
last = lines.index { |line| line.start_with?('  class NotificationActionScene') }
raise 'Missing native AppNotification boundary' unless first && last && first < last
Object.class_eval("module Programs\n#{lines[first...last].join}\nend", sdk, first + 1)

module InvitationNoticeShape
  module_function

  def assert(value, message)
    raise message unless value
  end

  def metadata
    {'invitation_id'=>91, 'table_id'=>7, 'live_session_id'=>'native-room-7',
      'sender'=>'Alice', 'created_at'=>100, 'expires_at'=>400, 'expires_in'=>300}
  end

  def notice(id, values = metadata, created_at: 100, sender: 'Alice')
    Programs::AppNotification.new(id: id, app_uuid: 'notification-shape-app',
      type: 'game_room.invitation', sender: sender, created_at: created_at, metadata: values)
  end

  def cleaner(rows)
    revoked, requests = [], []
    gateway = Object.new
    gateway.define_singleton_method(:list) { |*, **| requests << :list; rows }
    gateway.define_singleton_method(:revoke_many) { |_client, ids| requests << :revoke_many; revoked.concat(ids) }
    gateway.define_singleton_method(:revoke) { |_client, id| requests << :revoke; revoked << id }
    result = InvitationNotifications.new(client: :offline, app_uuid: 'notification-shape-app',
      gateway: gateway, current_user: -> { 'Bob' })
    [result, revoked, requests]
  end
end

include InvitationNoticeShape
checks = 0
malformed = [true, false, [], {}, ['91'], {'value'=>91}]
fields = %w[invitation_id table_id created_at expires_at expires_in native_expires_at]
fields.product(malformed).each do |field, value|
  broken = notice(101, JSON.parse(JSON.generate(metadata.merge(field=>value))))
  valid = notice(100)
  neighbor = notice(102, metadata.merge('invitation_id'=>92, 'table_id'=>8, 'live_session_id'=>'native-room-8'))
  before = Marshal.dump([broken, valid, neighbor].map(&:metadata))
  service, revoked, requests = cleaner([valid, broken, neighbor])
  pending = service.pending(recipient: 'Bob', now: 110)
  assert(pending.map { |row| row['notification_id'] } == [100, 102], "Bad #{field}/#{value.class} damaged pending neighbors")
  assert(service.with_opened(broken) { service.pending(recipient: 'Bob', now: 110) } == pending,
    "Bad opened #{field}/#{value.class} bypassed validation")
  reference = GameRoomInvitationIdentity.notification_reference(broken, recipient: 'Bob')
  assert(reference.nil?, "Bad #{field}/#{value.class} entered notification action")
  if %w[created_at expires_at expires_in native_expires_at].include?(field)
    assert(GameRoomNotificationTime.expires_at(broken) == 0, 'Malformed time escaped the deferred-notice boundary')
  end
  assert(service.revoke(pending.first) == 1 && revoked == [100], "Bad #{field}/#{value.class} damaged exact cleanup")
  revoked.clear
  assert(service.revoke_for_table(7, live_session_id: 'native-room-7') == 1 && revoked == [100],
    "Bad #{field}/#{value.class} damaged table cleanup")
  assert(requests.count(:list) == 4 && requests.count(:revoke_many) == 2, 'Validation added notification requests')
  assert(Marshal.dump([broken, valid, neighbor].map(&:metadata)) == before, 'Validation changed native metadata')
  checks += 1
end

# Keep old/coercible wire values and server-clock precedence exactly as before.
[91, 91.9, '91', '91rest'].each do |number|
  values = metadata.merge('invitation_id'=>number, 'table_id'=>number)
  service, = cleaner([notice(100, values)])
  row = service.pending(recipient: 'Bob', now: 110).fetch(0)
  assert(row['__id'] == 91 && row['table_id'] == 91, 'Valid scalar ID conversion changed')
  checks += 1
end

[
  [{}, 400], [{'expires_in'=>nil}, 400], [{'expires_in'=>0}, 400],
  [{'expires_in'=>-2}, 400], [{'expires_in'=>500}, 400],
  [{'expires_in'=>'50'}, 150], [{'expires_in'=>50.8}, 150],
  [{'native_expires_at'=>nil}, 400], [{'native_expires_at'=>0}, 400],
  [{'native_expires_at'=>'125'}, 125], [{'native_expires_at'=>125.8}, 125],
  [{'created_at'=>1, 'expires_at'=>99999}, 400]
].each do |extra, expected|
  item = notice(100, metadata.merge(extra))
  service, = cleaner([item])
  row = service.pending(recipient: 'Bob', now: 110).fetch(0)
  assert(row['created_at'] == 100 && row['expires_at'] == expected, "Expiry changed for #{extra}")
  assert(service.pending(recipient: 'Bob', now: expected).empty?, 'Boundary expiry extended')
  checks += 1
end

missing = metadata.reject { |key, _| %w[created_at expires_at expires_in native_expires_at].include?(key) }
item = notice(100, missing)
service, = cleaner([item])
assert(service.pending(recipient: 'Bob', now: 110).first.fetch('expires_at') == 400, 'Missing TTL lost default server expiry')
legacy = notice(100, missing, created_at: 0)
assert(GameRoomNotificationTime.expires_at(legacy) == 0, 'Missing old expiry became a false expired timestamp')
assert(GameRoomInvitationIdentity.notification_reference(legacy, recipient: 'Bob'), 'Old notice without dates cannot reach authoritative lookup')
legacy = notice(100, metadata.merge('created_at'=>'90', 'expires_at'=>'150'), created_at: 0)
service, = cleaner([legacy])
assert(service.pending(recipient: 'Bob', now: 110).first.values_at('created_at','expires_at') == [90,150], 'Old adapter dates changed')

# A table-watch envelope is also eligible for table-specific cleanup, without
# becoming an invitation or preventing a valid neighboring notice from removal.
module GameRoomTableWatch
  TYPE = 'game_room.table_created'.freeze
end
watch_class = Struct.new(:id, :app_uuid, :payload)
malformed.each do |value|
  watch = watch_class.new(103, 'notification-shape-app', {'type'=>GameRoomTableWatch::TYPE,
    'metadata'=>{'table_id'=>value, 'live_session_id'=>'native-room-7'}})
  service, revoked, = cleaner([watch, notice(100)])
  assert(service.revoke_for_table(7, live_session_id: 'native-room-7') == 1 && revoked == [100], 'Bad watch field blocked exact cleanup')
  checks += 1
end

puts "PASS #{checks} native invitation metadata cases; neighbors, opened action, cleanup, clock compatibility and no extra reads"
