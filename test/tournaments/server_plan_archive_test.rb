require 'tmpdir'
require_relative '../../lib/tournaments/server_plan_archive'
T = GameRoomTournaments
class ArchiveTestTable
  attr_accessor :on_insert, :on_select
  attr_reader :rows, :inserts
  def initialize; @rows, @inserts = [], 0; end
  def insert(row)
    @inserts += 1
    @rows << row.merge('__id' => @inserts, '__insertion_user' => 'guliwer')
    @on_insert&.call(@inserts)
    @rows.last
  end
  def select(where:, limit:)
    @on_select&.call
    @rows.select { |r| r['operation_key'] == where['operation_key'] }.first(limit).reverse
  end
end
def assert(value); raise 'Assertion failed' unless value; end
def rejected(klass)
  begin; yield; rescue klass; return; end
  raise "Expected #{klass}"
end
Dir.mktmpdir('plan-archive') do |directory|
  owner = 'guliwer'
  table = ArchiveTestTable.new
  journal = -> { T::OperationJournal.new(directory: directory, owner: 'guliwer', backend_identity: 'test-plan-server') }
  authorized = true
  verifier = ->(doc, anchor) { authorized && doc['status'] == 'candidate' && anchor['tournament_id'] == 5 }
  build = -> { T::ServerPlanArchive.new(table: table, journal: journal.call, user: -> { owner }, verify: verifier) }
  anchor = {'operation_key' => 'a'*64, 'tournament_id' => 5, 'publication_digest' => 'b'*64, 'roster_generation' => 'c'*64}
  document = {'status' => 'candidate', 'matches' => Array.new(30) { |i| {'number' => i, 'players' => ['Żółw', 'guliwer'], 'notes' => 'ą'*50} }}
  parts = T::ServerPlanDocument.encode(document, anchor: anchor).size
  # The last insert commits, but its acknowledgement is lost.
  table.on_insert = ->(n) { raise IOError, 'Lost acknowledgement' if n == parts }
  rejected(IOError) { build.call.publish(intent_id: 'lost-ack', document: document, anchor: anchor) }
  first = journal.call.find(kind: 'plan_document', intent_id: 'lost-ack')
  assert(first['status'] == 'attempted' && table.inserts == parts)
  table.on_insert = nil
  recovered = build.call.reconcile(first['id'])
  assert(recovered['status'] == 'confirmed' && table.inserts == parts)
  assert(build.call.publish(intent_id: 'lost-ack', document: document, anchor: anchor.merge('operation_key' => 'd'*64)) == recovered)
  assert(table.inserts == parts)
  # A partial multirow write stays attempted across a cold controller.
  partial_anchor = anchor.merge('operation_key' => 'e'*64)
  table.on_insert = ->(n) { raise IOError, 'Disconnected' if n == parts + 2 }
  rejected(IOError) { build.call.publish(intent_id: 'partial', document: document, anchor: partial_anchor) }
  partial = journal.call.find(kind: 'plan_document', intent_id: 'partial')
  count = table.inserts
  rejected(T::ServerPlanArchive::Unconfirmed) { build.call.publish(intent_id: 'partial', document: document, anchor: partial_anchor) }
  assert(table.inserts == count && journal.call.fetch(partial['id'])['status'] == 'attempted')
  # Read failure is propagated, never interpreted as an empty successful read.
  table.on_select = -> { raise IOError, 'Read failed' }
  rejected(IOError) { build.call.reconcile(recovered['id']) }
  table.on_select = nil
  # Account changes at a network boundary latch even if the account returns.
  controller = build.call
  table.on_select = -> { owner = 'other' }
  rejected(T::ServerPlanArchive::ContextChanged) { controller.reconcile(recovered['id']) }
  table.on_select = nil
  owner = 'guliwer'
  rejected(T::ServerPlanArchive::ContextChanged) { controller.reconcile(recovered['id']) }
  # Current roster/publication authorization is required before any journal/write.
  authorized = false
  rejected(T::Publication::Invalid) { build.call.publish(intent_id: 'stale', document: document, anchor: anchor) }
  assert(journal.call.find(kind: 'plan_document', intent_id: 'stale').nil? && table.inserts == count)
  authorized = true
  # An uncertain local claim is never followed by an insert or a new claim.
  claim_journal = journal.call
  original_claim = claim_journal.method(:claim)
  claim_journal.define_singleton_method(:claim) do |id|
    original_claim.call(id)
    raise IOError, 'Claim persisted but acknowledgement lost'
  end
  claim_writer = T::ServerPlanArchive.new(table: table, journal: claim_journal, user: -> { owner }, verify: verifier)
  claim_anchor = anchor.merge('operation_key' => 'f'*64)
  rejected(IOError) { claim_writer.publish(intent_id: 'claim-lost', document: document, anchor: claim_anchor) }
  rejected(T::ServerPlanArchive::Unconfirmed) { build.call.publish(intent_id: 'claim-lost', document: document, anchor: claim_anchor) }
  assert(table.inserts == count && journal.call.find(kind: 'plan_document', intent_id: 'claim-lost')['status'] == 'attempted')
  # A programming failure in the authorization verifier propagates unchanged.
  broken = T::ServerPlanArchive.new(table: table, journal: journal.call, user: -> { owner }, verify: ->(*) { raise NoMethodError, 'Verifier bug' })
  rejected(NoMethodError) { broken.publish(intent_id: 'bug', document: document, anchor: anchor) }
  assert(journal.call.find(kind: 'plan_document', intent_id: 'bug').nil?)
  # Malformed changed intent cannot create another attempt under an existing intent.
  rejected(T::OperationJournal::Conflict) { build.call.publish(intent_id: 'lost-ack', document: document.merge('extra' => true), anchor: anchor) }
  assert(table.inserts == count)
end
puts 'PASS durable server plan archive: lost acknowledgement, cold recovery without resend, partial write, account latch, authorization and changed-intent refusal'
