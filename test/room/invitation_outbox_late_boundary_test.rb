require_relative '../support/native_tasks'
require_relative '../support/assertions'
require_relative '../../lib/invitation_response_outbox'
Object.include(GameRoomTest::Assertions)
module EltenAPI::LiveSessions
  class Error < StandardError; end
  class TimeoutError < Error; end
end

class DeferredInvitationWorker
  attr_reader :operation
  def take; value, @result = @result, nil; value; end
  def busy?; !@operation.nil?; end
  def closed?; false; end
  def start(&operation); raise 'Worker already occupied' if busy?; @operation = operation; true; end
  def finish
    current, @operation = @operation, nil
    @result = [current.call, nil]
  rescue StandardError => error
    @result = [nil, error]
  end
end

worker = DeferredInvitationWorker.new
now, user, calls = 10.0, 'Bob', []
outbox = InvitationResponseOutbox.new(worker: worker, clock: -> { now }, current_user: -> { user })
base = {'__id' => 91, 'table_id' => 7, 'live_session_id' => 'native', 'sender' => 'Alice', 'recipient' => 'Bob'}
rows = [base, base.merge('sender' => 'Carol')]
rows.each do |row|
  first = true
  outbox.submit(row, 'rejected') do |snapshot, response|
    calls << [snapshot['sender'], response]
    if first
      first = false
      raise EltenAPI::LiveSessions::TimeoutError, 'unknown acknowledgement'
    end
  end
end
base['sender'] = 'Mutated after submit'
now += 16
outbox.tick
worker.finish
outbox.tick
worker.finish
outbox.tick
assert(calls == [['Alice', 'rejected'], ['Carol', 'rejected'], ['Alice', 'rejected'], ['Carol', 'rejected']],
  'Retry changed captured sender/decision or merged colliding invitation responses')
rows.last['sender'] = 'Carol'
outbox.submit(rows.last, 'accepted') { raise 'A duplicate response was sent again' }

# The retry is admitted under Bob, but the task has not started. Once the
# account changes it must not emit Bob's response under another identity.
pending = rows.last.merge('__id' => 92)
attempts = 0
outbox.submit(pending, 'accepted') do |_snapshot, _response|
  attempts += 1
  raise EltenAPI::LiveSessions::TimeoutError, 'before receipt'
end
now += 16
outbox.tick
assert(worker.busy?, 'The retry was not queued for the intended boundary')
user = 'Other'
worker.finish
outbox.tick
assert(attempts == 1, 'Deferred old-account retry sent after the account changed')

# A stale worker completion must not replace a new job after Bob -> Other ->
# Bob. The new explicit rejection is still the immutable current decision.
user = 'Bob'
outbox.submit(pending, 'accepted') { raise EltenAPI::LiveSessions::TimeoutError, 'retry again' }
now += 16
outbox.tick
user = 'Other'
outbox.tick
user = 'Bob'
new_calls = 0
outbox.submit(pending, 'rejected') { new_calls += 1 }
worker.finish
outbox.tick
answer = outbox.submit(pending, 'accepted') { raise 'Late completion erased the new decision' }
assert(answer == 'rejected' && new_calls == 1, 'ABA completion changed a newer explicit response')
puts 'PASS scoped response retry snapshots, unknown ACK, deferred account change and stale completion ABA'
