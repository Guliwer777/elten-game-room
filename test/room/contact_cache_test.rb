require_relative "../support/log"
require_relative "../support/native_tasks"
require_relative "../../lib/game_room_contacts"
require 'timeout'

def assert(value, message); raise message unless value; end
class ContactWorker
  attr_reader :starts
  def start(&operation); return false if busy?; @operation = operation; @starts = @starts.to_i + 1; true; end
  def busy?; @operation != nil || @result != nil; end
  def closed?; @closed == true; end
  def finish
    @result = [@operation.call, nil]
  rescue StandardError => error
    @result = [nil, error]
  ensure
    @operation = nil
  end
  def take; result, @result = @result, nil; result; end
  def close; @closed = true; @result = nil; end
end

now, names, error = 0.0, [" Bob ", "ALICE"], nil
worker = ContactWorker.new
cache = GameRoomContacts::Cache.new(user: "OWNER", worker: worker, clock: -> { now }, loader: -> { raise error if error; names })
assert(cache.include?("Bob").nil?, "unknown contacts must remain unknown")
100.times { assert(cache.include?("Eve").nil?, "unknown list became a rejection/permission") }
assert(worker.starts == 1, "burst scheduled duplicate requests")
worker.finish
assert(cache.include?("bOb") && !cache.include?("Eve") && cache.user == "owner", "case-normalized contacts are wrong")
assert(cache.snapshot.frozen?, "a caller can corrupt another caller's cache")
now = 59.9
cache.snapshot
assert(worker.starts == 1, "fresh cache queried again")
now = 60
names = ["Eve"]
assert(cache.include?("Bob"), "refresh discarded the last known list")
assert(worker.starts == 2, "TTL did not schedule a refresh")
worker.finish
assert(!cache.include?("Bob") && cache.include?("Eve") && cache.revision == 2, "add/remove was not applied")
cache.snapshot(force: true)
assert(cache.snapshot.nil?, "explicit R exposed the pre-refresh contact list")
100.times { cache.snapshot(force: true) }
assert(worker.starts == 3, "manual refresh overlaps the running read")
error = IOError.new("offline")
worker.finish
assert(cache.include?("Eve"), "network error erased a known list")
now += 14.9
100.times { cache.snapshot }
assert(worker.starts == 3, "failure caused a busy retry loop")
now += 0.1
cache.snapshot(force: true)
assert(worker.starts == 4, "backoff never allows recovery")
error = nil
names = []
worker.finish
assert(cache.snapshot == {}, "an empty successful list was mistaken for unknown")
cache.close
cache.snapshot(force: true)
assert(worker.starts == 4, "closed cache restarted")

# The real worker waits for a deliberately slow provider while UI-like reads
# continue. No network wait or join occurs inside snapshot/include?/revision.
started, release = Queue.new, Queue.new
real = GameRoomContacts::Cache.new(user: "Alice", loader: -> { started << true; release.pop; ["Bob"] })
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
real.include?("Bob")
initial_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
assert(initial_duration < 0.5, "initial UI read blocked behind network: #{initial_duration}s")
# Dispatch scheduling is not time spent in the UI calls under examination.
Timeout.timeout(3) { started.pop }
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
2000.times { real.include?("Eve"); real.revision }
duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
assert(duration < 0.5, "memory reads blocked behind network: #{duration}s")
assert(initial_duration + duration < 0.5, "combined UI reads blocked behind network: #{initial_duration + duration}s")
release << true
wait_background_work(real.instance_variable_get(:@worker)) or raise "worker hung"
assert(real.include?("Bob"), "slow read never reached the cache")
real.close
puts "PASS contacts: finite worker, TTL, concurrent/coalesced reads, failure backoff, empty list, close; 2000 UI reads #{(duration * 1000).round(2)} ms"
