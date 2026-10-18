require_relative '../../lib/invitation_repository'

def assert(condition, message); raise message unless condition; end
transport = Object.new
def transport.pending_invitations; []; end
tables = [7, 8].map { |id| {'__id'=>id, 'status'=>'waiting', '__live_session_id'=>"native-#{id}"} }
rows = tables.each_with_index.map do |table, index|
  {'__id'=>91, 'table_id'=>table['__id'], 'live_session_id'=>table['__live_session_id'],
    'sender'=>%w[Alice Carol][index], 'recipient'=>'Bob', 'created_at'=>100, 'expires_at'=>400}
end
repository = InvitationRepository.new(transport: transport, notification_source: ->(*) { rows })
listed = repository.pending_for('Bob', tables: tables, now: 110)
assert(listed.map(&:table_id).sort == [7,8], 'Different scopes with the same random ID were collapsed')
assert(repository.pending_by_id(91, 'Bob', tables: tables, now: 110).nil?, 'An ambiguous ID picked a different invitation')
selected = listed.find { |item| item.table_id == 7 }
assert(repository.pending_by_id(selected, 'Bob', tables: tables, now: 110).table_id == 7, 'Exact scope lookup failed')
repository.respond(selected, recipient: 'Bob', response: 'rejected', now: 111)
assert(repository.pending_for('Bob', tables: tables, now: 112).map(&:table_id) == [8], 'Reply resolved another table')
assert(repository.respond(selected, recipient: 'Bob', response: 'accepted', now: 112)['response'] == 'rejected', 'Duplicate reply changed the decision')
rows << rows.last.merge('sender'=>'Dave')
assert(repository.pending_for('Bob', tables: tables, now: 112).map(&:sender).sort == %w[Carol Dave], 'Distinct senders were collapsed')

now, user, sent = 100.0, 'Bob', []
outbox = InvitationResponseOutbox.new(worker: Object.new, clock: -> { now }, current_user: -> { user })
rows.last(2).each { |row| outbox.submit(row, 'rejected') { |value, _| sent << value['sender'] } }
outbox.submit(rows.last, 'accepted') { raise 'Exact duplicate reply was resent' }
assert(sent == %w[Carol Dave], 'Outbox merged independent senders')
user = 'Other'
begin
  outbox.submit(rows.last, 'accepted') { raise 'A foreign account sent the reply' }
  raise 'Outbox accepted another current account'
rescue ArgumentError
end
puts 'Invitation repository scope passed (table/native/user/sender, ambiguous legacy ID, immutable reply/outbox)'

user = 'Bob'
guarded = InvitationRepository.new(transport:transport,notification_source:->(*) { rows },current_user:-> { user })
own = guarded.pending_for('Bob',tables:tables,now:110).first
user = 'Other'
assert(guarded.pending_for('Bob',tables:tables,now:110).empty?, 'Repository returned another account invitations')
begin
  guarded.respond(own,recipient:'Bob',response:'accepted')
  raise 'Repository accepted stale-account decision'
rescue ArgumentError
end
user = 'Bob'
interrupted = InvitationRepository.new(transport:transport,notification_source:->(*) { user='Other'; rows },current_user:-> { user })
assert(interrupted.pending_for('Bob',tables:tables,now:110).empty?, 'Repository returned a response across account change')

# Existing receipt fields must resolve one sender/native reservation only;
# legacy replies without enough scope never unlock every matching send.
InvitationRepository::SENT_LOCK.synchronize do
  InvitationRepository::SENT.clear
  InvitationRepository::SENT[:first] = rows[1]
  InvitationRepository::SENT[:second] = rows[1].merge('live_session_id'=>'another-native')
  InvitationRepository::SENT[:third] = rows[1].merge('sender'=>'Dave')
end
InvitationRepository.resolve_sent(91,table_id:8,recipient:'Bob')
assert(InvitationRepository::SENT.size == 3, 'Ambiguous legacy receipt unlocked independent reservations')
assert(InvitationRepository.sent_for_receipt(91,table_id:8,recipient:'Bob',sender:'Carol').nil?, 'Legacy receipt picked a native generation')
receipt = InvitationRepository.sent_for_receipt(91,table_id:8,recipient:'Bob',sender:'Carol',live_session_id:'native-8')
assert(receipt.equal?(rows[1]), 'Exact receipt lost the matching reservation')
InvitationRepository.resolve_sent(receipt)
assert(InvitationRepository::SENT.size == 2 && !InvitationRepository::SENT.value?(receipt), 'Exact receipt removed another scope')
puts 'PASS repository authenticated-account boundaries and unambiguous receipt resolution'
