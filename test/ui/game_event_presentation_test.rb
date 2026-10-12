require_relative "../../lib/game_event_presentation"

def assert(value, message)
  raise message unless value
end

class PresentationTestSound
  attr_accessor :done, :broken
  attr_reader :length, :closed
  def initialize(length)
    @length = length
    @done = false
  end
  def finished?
    raise "device disappeared" if @broken
    @done || @closed
  end
  def close
    @closed = true
  end
end

now = 0.0
queue = GameRoomEventPresentation.new(clock: -> { now }, initial_replay: :ready)
launch = PresentationTestSound.new(3.366)
hit = PresentationTestSound.new(2.861)
log = []
queue.enqueue(replay: :shot, start: -> { log << :launch; launch }, finish: -> { log << :launch_finished })
queue.enqueue(replay: :hit, start: -> { log << :hit; hit }, finish: -> { log << :next_turn })
assert(queue.advance && queue.busy?, "launch did not start")
assert(queue.visible_replay == :shot && log == [:launch], "answer appeared before launch finished")
now = 1.0
assert(!queue.advance && log == [:launch], "timer started another event while sound plays")
# Completion, not a guessed fixed delay, releases the next event.
launch.done = true
assert(queue.advance && log == [:launch, :launch_finished, :hit], "actual completion did not start the hit")
assert(queue.visible_replay == :hit && queue.busy?, "hit state or pause missing")
queue.enqueue(replay: :later, start: -> { log << :later; nil })
assert(!queue.advance && !log.include?(:later), "newly received event jumped the queue")
hit.done = true
queue.advance
assert(log == [:launch, :launch_finished, :hit, :next_turn, :later] && !queue.busy?, "next turn or later event lost")

result = PresentationTestSound.new(8.0)
queue.enqueue(replay: :finished, start: -> { result }, defer_replay: true)
queue.advance
assert(queue.visible_replay == :later && queue.busy?, "restart became visible during result sound")
result.done = true
queue.advance
assert(queue.visible_replay == :finished && !queue.busy?, "finished screen never released")

# Disabled/missing audio never imposes an artificial pause, even in a batch.
10.times { |index| queue.enqueue(replay: index, start: -> { [nil, false] }) }
queue.advance
assert(!queue.busy? && queue.visible_replay == 9, "silent playback stalled")

# Watchdog is only for broken handles; normal long clips are not cut to 5s.
slow = PresentationTestSound.new(10)
queue.enqueue(replay: :slow, start: -> { slow })
queue.advance
now += 8
queue.advance
assert(queue.busy? && !slow.closed, "long valid sound was cut short")
now += 5
queue.advance
assert(!queue.busy? && slow.closed, "stuck device blocked the game indefinitely")
broken = PresentationTestSound.new(3)
broken.broken = true
queue.enqueue(replay: :broken, start: -> { broken })
queue.advance
assert(!queue.busy? && broken.closed, "device exception blocked the game")

owned = PresentationTestSound.new(5)
foreign = PresentationTestSound.new(5)
queue.enqueue(replay: :old, start: -> { owned })
queue.enqueue(replay: :discarded, start: -> { raise "played after leaving" })
queue.advance
queue.close
queue.advance
assert(!queue.busy? && queue.visible_replay == nil && owned.closed && !foreign.closed, "leaving did not isolate owned sounds")
# Explicit pauses do not depend on audio or speech completion. A late frame
# gives the following stage its own delay rather than releasing both at once.
now = 0.0
queue = GameRoomEventPresentation.new(clock: -> { now }, initial_replay: :before)
log = []
queue.enqueue(replay: :after, defer_replay: true, delay: 1.0, wait_for_sounds: false,
  start: -> { log << :roll; nil })
queue.enqueue(replay: :after, delay: 2.0, wait_for_sounds: false,
  start: -> { log << :field; nil }, finish: -> { log << :turn })
queue.advance
assert(log == [:roll] && queue.visible_replay == :before, 'Roll pause exposed the destination')
now = 0.999
assert(!queue.advance && log == [:roll], 'Roll pause ended early')
now = 5.0
queue.advance
assert(log == [:roll, :field] && queue.busy?, 'Late frame collapsed both pauses')
now = 6.999
queue.advance
assert(log == [:roll, :field], 'Next turn was announced early')
now = 7.0
queue.advance
assert(log == [:roll, :field, :turn] && !queue.busy?, 'Next turn did not resume')
queue.enqueue(replay: :cancelled, delay: 2.0, start: -> { nil }, finish: -> { raise 'Late turn after close' })
queue.advance
queue.close
now = 20.0
queue.advance
assert(!queue.busy?, 'Closing retained a scheduled pause')
puts "PASS serial presentation: sounds, muted audio, explicit pauses, late frames, final view, watchdog, close; no sleeps"
