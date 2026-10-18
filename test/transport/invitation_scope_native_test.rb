require_relative '../support/native_live_sessions'

broker = NativeLiveSessionsBroker.new
transports = %w[Alice Carol Bob].to_h do |user|
  [user, GameRoomTransport.new(ProgramDouble.new(broker.endpoint(user)))]
end
transports.each_value(&:start)
tables = %w[Alice Carol].map do |user|
  $game_room_test_user = user
  table = transports[user].create_room(name:"#{user} private room",game:'uno',owner:user,game_options:'{}',private_table:true)
  transports[user].invite_user(table_id:table['__id'],user:'Bob',metadata:{'purpose'=>'game_invitation','invitation_id'=>91})
  table
end
$game_room_test_user = 'Bob'
pending = transports['Bob'].pending_invitations
assert(pending.map { |row| row['table_id'] }.sort == tables.map { |row| row['__id'] }.sort, 'Native cache overwrote a colliding invitation')
assert(pending.map { |row| row['sender'] }.sort == %w[Alice Carol], 'Native inviter authority was lost')
assert(pending.all? { |row| row['live_session_id'].to_s != '' }, 'Native UUID missing from invitation scope')
assert(transports['Bob'].reject_invitation(table_id:tables.first['__id'],invitation_id:91), 'Exact native rejection failed')
assert(transports['Bob'].pending_invitations.map { |row| row['table_id'] } == [tables.last['__id']], 'Native rejection resolved another room')
assert(transports['Bob'].accept_invitation(table_id:tables.last['__id'],invitation_id:91), 'Other native invitation cannot be accepted')
assert(transports['Bob'].current_room('Bob')['__id'] == tables.last['__id'], 'Accepted a different native room')
puts 'Native invitation scopes passed (two private rooms, same app ID, authenticated inviter, independent decline/accept)'

# Replacement endpoint/account cannot inherit callbacks or pending native
# objects that still authorize the old recipient. No server rejection is used
# merely to discard the old local view.
old_endpoint = broker.endpoint('Bob')
program = ProgramDouble.new(old_endpoint)
switched = GameRoomTransport.new(program)
switched.start
$game_room_test_user = 'Alice'
fresh_room = transports['Alice'].create_room(name:'Old endpoint',game:'uno',owner:'Alice',game_options:'{}',private_table:true)
transports['Alice'].invite_user(table_id:fresh_room['__id'],user:'Bob',metadata:{'invitation_id'=>92})
$game_room_test_user = 'Bob'
old_rows = switched.pending_invitations
old_invitation = old_rows.find { |row| row['__id'] == 92 }.fetch('__native_invitation')
program.live_sessions = broker.endpoint('Other')
$game_room_test_user = 'Other'
assert(switched.pending_invitations.empty?, 'Old endpoint invitations leaked into another account')
old_endpoint.deliver_invitation(old_invitation)
assert(switched.pending_invitations.empty?, 'Delayed old callback reintroduced another account')
assert(!switched.accept_invitation(table_id:fresh_room['__id'],invitation_id:92), 'Old native invitation used by another account')
assert(old_invitation.pending?, 'Account switching rejected the old account invitation on the server')
$game_room_test_user = 'Alice'
transports['Alice'].invite_user(table_id:fresh_room['__id'],user:'Other',metadata:{'invitation_id'=>93,'sender'=>'Forged'})
$game_room_test_user = 'Other'
assert(switched.pending_invitations.empty?, 'Untrusted native metadata replaced the authenticated inviter')
$game_room_test_user = 'Alice'
transports['Alice'].invite_user(table_id:fresh_room['__id'],user:'Other',metadata:{'invitation_id'=>94,'sender'=>'Alice'})
$game_room_test_user = 'Other'
own = switched.pending_invitations
assert(own.size == 1 && own.first['recipient'] == 'Other' && own.first['sender'] == 'Alice', 'New endpoint cannot receive its own valid invitation')
target = own.first.fetch('__native_invitation')
original_reject = target.method(:reject)
target.define_singleton_method(:reject) { raise EltenAPI::LiveSessions::TimeoutError, 'before reject ACK' }
begin
  switched.reject_invitation(table_id:fresh_room['__id'],invitation_id:94)
  raise 'Missing controlled timeout'
rescue EltenAPI::LiveSessions::TimeoutError
end
assert(switched.pending_invitations.map { |row| row['__id'] } == [94], 'Failed rejection lost its own retry scope')
target.define_singleton_method(:reject,original_reject)
assert(switched.reject_invitation(table_id:fresh_room['__id'],invitation_id:94), 'Same scoped native rejection could not retry')
assert(switched.pending_invitations.empty?, 'Resolved native invitation reappeared')
puts 'PASS native endpoint/account/callback isolation, authenticated sender and scoped failed-rejection retry'
