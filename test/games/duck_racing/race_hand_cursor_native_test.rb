require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_layout'

include GameRoomTest::Assertions
h = DuckGameAdapterTest::Harness.new
h.start(seed: h.seed_for('good_draw'))
driver = DuckChallengeNativeDriver.new
surface = GameSurfaces.build(h.game.surface_spec(h.replay, 'Alice'))
form = driver.form(surface)
field = surface.fields.first
driver.frame(form, driver.tap(0x23))
assert_equal('Roll the die', field.options[field.index])
card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'good_draw' }
h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id}}, actor: 'Alice')
surface = GameSurfaces.reconcile(h.game.surface_spec(h.replay, 'Alice'), previous: surface, state: surface.state)
assert_equal(field, surface.fields.first, 'Drawing rebuilt the native hand control')
assert_equal('Roll the die', field.options[field.index], 'Drawing moved the cursor off Roll')
assert_equal(nil, surface.take_cursor_announcement(0), 'Drawing announced the last card')

# A completed roll removes legal permission, not the permanent list row.
h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
assert(h.replay.state[:round].nil?, 'Choose an ordinary landing for this cursor fixture')
surface = GameSurfaces.reconcile(h.game.surface_spec(h.replay, 'Alice'), previous: surface, state: surface.state)
assert_equal('Roll the die', field.options[field.index], 'Passing the turn selected a card')
assert_equal(nil, surface.take_cursor_announcement(0))
events = []
surface.on_action { |action| events << action }
driver.frame(form, driver.tap(0x0D))
assert_equal('roll', events.last.name)
assert(h.plan(events.last, actor: 'Alice').first != :ok, 'The permanent Roll row permitted an out-of-turn roll')

# An unchanged refresh while writing keeps the draft, selection and focus.
chat = form.fields.last
form.index = form.fields.index(chat)
chat.index, chat.check = 5, 2
before = [chat.text, chat.index, chat.check, form.index]
surface = GameSurfaces.reconcile(h.game.surface_spec(h.replay, 'Alice'), previous: surface, state: surface.state)
assert_equal(before, [chat.text, chat.index, chat.check, form.index])
assert_equal('Roll the die', field.options[field.index])

# The shared layout restores the command after a temporary challenge surface.
layout = GameRoomLayout::Screen.new(view_spec: h.game.game_view_spec(h.replay, 'Alice'))
layout.surface.fields.first.index = layout.surface.fields.first.options.length - 1
layout.update(view_spec: GameRoomLayout::ViewSpec.new(surface: h.game.send(:info_surface, 'Challenge')),
  history_items: [], user_items: [], users_header: '')
layout.update(view_spec: h.game.game_view_spec(h.replay, 'Alice'),
  history_items: [], user_items: [], users_header: '')
returned = layout.surface.fields.first
assert_equal('Roll the die', returned.options[returned.index], 'A challenge erased the selected Roll command')
puts 'PASS native Duck hand: draw, roll, other turn, legality, stable control, chat draft/focus and challenge return'
