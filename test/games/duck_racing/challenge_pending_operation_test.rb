require_relative '../../support/duck_challenge_native'
require_relative '../../../lib/game_room_pending_operation'
include DuckChallengeTest

driver = DuckChallengeNativeDriver.new
surface = challenge_surface(challenge_state('copy_number'))
form = driver.form(surface)
field = surface.fields.first
notices, clock = [], [10.0]
form.define_singleton_method(:speak) { |text, *| notices << text }
layout = Struct.new(:form, :surface, :binding_generation, :session_id).new(form, surface, 1, 42)
token = EltenAPI::Tasks::CancellationToken.new
pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 42,
  token: token, title: 'Refreshing the challenge', clock: -> { clock.first })

# The client drains input every frame, including frames pumped by a network
# task. No input is not an attempt to submit another action.
60.times do
  driver.frame(form)
  assert_equal([], surface.take_input(form))
end
assert_equal([], notices, 'Idle challenge frames announced a rejected action')
driver.frame(form, driver.tap(0x34), characters: '4')
assert_equal([], surface.take_input(form))
assert_equal('4', field.text, 'Pending refresh stopped ordinary text editing')
assert_equal([], notices, 'Typing an answer announced a rejected action')
driver.frame(form, driver.tap(0x0D, modifiers: [0x11]))
assert_equal([], surface.take_input(form))
assert_equal([], notices, 'An unrelated modified key announced a rejected action')

# A real attempt during the outstanding request must still be refused. The
# refusal must not turn into a delayed answer after the request finishes.
driver.frame(form, driver.tap(0x0D))
assert_equal([], surface.take_input(form))
assert_equal(['Please wait...'], notices)
pending.close
driver.frame(form)
assert_equal([], surface.take_input(form), 'A refused answer survived the pending request')
driver.frame(form, driver.tap(0x0D))
assert_equal([{kind: :answer, value: '4', press_id: 1}], surface.take_input(form))

# A request may start after key collection but before the client drains it.
# Retyping creates a new attempt; unedited Enter is now intentionally ignored.
driver.frame(form, driver.tap(0x35), characters: '5')
driver.frame(form, driver.tap(0x0D))
pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 42,
  token: token, title: 'Refreshing the challenge', clock: -> { clock.first })
assert_equal([], surface.take_input(form), 'Queued input bypassed the request guard')
assert_equal(2, notices.length)
pending.close
assert_equal([], surface.take_input(form), 'Rejected queued input was replayed')

# Preserve the shared delayed notice for a genuinely long operation. Empty
# frames should not speak, but the pending operation itself may after 5 s.
pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 42,
  token: token, title: 'Refreshing the challenge', clock: -> { clock.first })
clock[0] += 5.1
pending.update
assert_equal(3, notices.length)
10.times do
  pending.update
  assert_equal([], surface.take_input(form))
end
assert_equal(3, notices.length, 'Idle frames repeated the long-operation notice')
pending.close
surface.deactivate_input

# Like the other game surfaces, a pending request blocks activation, not
# browsing the available commands in a native list.
model = challenge_state('risky_dice')
surface = challenge_surface(model, seat: ENGINE.current_turn(model))
form = driver.form(surface)
form.define_singleton_method(:speak) { |text, *| notices << text }
layout = Struct.new(:form, :surface, :binding_generation, :session_id).new(form, surface, 1, 43)
pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: 7, session_id: 43,
  token: token, title: 'Refreshing the challenge', clock: -> { clock.first })
before = notices.length
driver.frame(form, driver.tap(0x28))
assert_equal(1, surface.fields.first.index, 'Pending refresh blocked list navigation')
assert_equal([], surface.take_input(form))
assert_equal(before, notices.length, 'Browsing the commands announced a rejected action')
driver.frame(form, driver.tap(0x26)) # Activate rolling, not saving an empty result.
driver.frame(form, driver.tap(0x0D))
assert_equal([], surface.take_input(form))
assert_equal(before + 1, notices.length, 'Activating a list command bypassed the guard')
pending.close
surface.deactivate_input
$activecontrols = []
puts 'PASS Duck pending refresh: idle frames, editing, modifiers and navigation stay silent, actual commands remain guarded, no deferred input, long-request notice preserved'
