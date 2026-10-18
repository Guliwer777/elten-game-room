require_relative '../../lib/invitation_notifications'

def assert(condition, message); raise message unless condition; end
Notice = Struct.new(:id, :app_uuid, :type, :sender, :metadata, :revoked, keyword_init: true)
gateway = Object.new
rows = [7, 8].each_with_index.map do |table, index|
  sender = %w[Alice Carol][index]
  Notice.new(id: 100 + index, app_uuid:'test-app', type:'game_room.invitation', sender:sender,
    metadata:{'invitation_id'=>91, 'table_id'=>table, 'live_session_id'=>"native-#{table}",
      'sender'=>sender, 'created_at'=>100, 'expires_at'=>400}, revoked:false)
end
revoked = []
gateway.define_singleton_method(:list) { |*, **| rows.reject(&:revoked) }
gateway.define_singleton_method(:revoke_many) { |_client, ids| revoked.concat(ids); rows.each { |row| row.revoked=true if ids.include?(row.id) } }
gateway.define_singleton_method(:revoke) { |_client, id| revoked << id }
user = 'Bob'
cleaner = InvitationNotifications.new(client: :client, app_uuid:'test-app', gateway:gateway, current_user: -> { user })
failures = []
pending = cleaner.pending(recipient:'Bob', now:110)
failures << 'Listing collapsed two authenticated senders/tables' unless pending.map { |row| row['table_id'] }.sort == [7,8]
count = cleaner.revoke(91)
failures << 'Ambiguous legacy ID revoked unrelated notifications' unless count.zero? && revoked.empty?
raise failures.join('; ') unless failures.empty?
assert(cleaner.revoke(pending.first) == 1 && revoked == [100], 'Exact rejection revoked a different table')
assert(cleaner.pending(recipient:'Bob',now:110).map { |row| row['table_id'] } == [8], 'Other notification disappeared')
forged = rows.last.dup
forged.id = 102
forged.metadata = forged.metadata.merge('sender'=>'Alice')
rows << forged
assert(cleaner.pending(recipient:'Bob',now:110).length == 1, 'Claimed sender overrode authenticated sender')
cleaner.with_opened(rows.first) do
  assert(cleaner.pending(recipient:'Bob',now:110).map { |row| row['table_id'] }.sort == [7,8], 'Opening a read notice lost its exact scope')
end
assert(cleaner.pending(recipient:'Bob',now:400).empty?, 'Expired notice retained scope')
before = revoked.dup
user = 'Other'
assert(cleaner.pending(recipient:'Bob',now:110).empty?, 'Foreign account queried old recipient')
assert(cleaner.revoke(pending.last,notification_id:101).zero? && revoked == before, 'Foreign account revoked a captured server notice ID')
user = 'Bob'
gateway.define_singleton_method(:list) { |*, **| user = 'Other'; rows.reject(&:revoked) }
assert(cleaner.pending(recipient:'Bob',now:110).empty?, 'Account change during the request returned an old invitation')
user = 'Bob'
assert(cleaner.revoke(pending.last).zero? && revoked == before, 'Account change during lookup revoked a notice')
puts 'Invitation notification scope passed (collision/list/revoke/read opening/author/expiry)'
