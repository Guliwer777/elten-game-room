require_relative '../support/card_hand_cursor'

def commanded_hand(ids, command: true, epoch: '1', choices: false, select_drawn: nil)
  spec = hand_spec(ids, epoch: epoch, choices: choices)
  spec.zones.first.select_drawn = select_drawn
  spec.zones.first.commands = command ? [GameSurfaces::Command.new(id: 'roll', label: 'Roll', enabled: true)] : []
  spec
end

surface = GameSurfaces.build(commanded_hand(%w[A B]))
events = []
surface.on_action { |action| events << action }
field = surface.fields.first
assert(field.options == %w[A B Roll], 'Command is not after the cards')
field.index = 2
field.trigger(:select, [2])
assert(events.last.kind == 'command' && events.last.name == 'roll', 'Roll emitted a fake card action')
cursor = surface.state['hand_cursors']['hand']
assert(cursor['ids'] == %w[A B] && cursor['raw_ids'] == %w[A B], 'Command polluted hand IDs')
surface.update_spec(commanded_hand(%w[A B]))
assert(selected(surface) == 'Roll' && surface.take_cursor_announcement(0).nil?, 'Unchanged refresh moved or spoke')
restored = GameSurfaces.build(commanded_hand(%w[A B]), state: surface.state)
assert(selected(restored) == 'Roll', 'Reconstruction lost the selected command')
surface.handle_command('sort_cards', 'mode' => 'number', 'toggle' => true)
assert(selected(surface) == 'Roll' && field.options.last == 'Roll', 'Sorting moved command into cards')
surface.update_spec(commanded_hand(%w[A B C]))
assert(selected(surface) == 'C' && surface.take_cursor_announcement(0) == 'C', 'Draw did not select the new physical card')
field.index = 3
surface.update_spec(commanded_hand(%w[A C]))
assert(selected(surface) == 'Roll' && surface.take_cursor_announcement(0).nil?, 'Removal lost command selection')
surface.update_spec(commanded_hand(%w[A C], command: false))
assert(%w[A C].include?(selected(surface)), 'Removed command left invalid cursor')
surface.update_spec(commanded_hand([], epoch: '2'))
assert(field.options == ['Roll'] && selected(surface) == 'Roll', 'Empty hand cannot roll')
field.trigger(:select, [0])
assert(events.last.name == 'roll', 'Empty hand emitted a card')
surface.update_spec(commanded_hand(%w[D E], epoch: '3'))
assert(selected(surface) == 'D', 'New deal retained old command cursor')
field.index = 2
surface.handle_command('navigate_playable_card', 'hand_id' => 'hand', 'card_ids' => ['E'], 'direction' => -1)
assert(selected(surface) == 'E', 'Playable navigation included roll')
choice = GameSurfaces.build(commanded_hand(%w[A B], choices: true))
choice.fields.first.trigger(:select, [0])
assert(choice.fields.first.options == ['Choice'], 'Command entered a card choice')
choice.cancel_pending_action!
assert(choice.fields.first.options == %w[A B Roll], 'Cancelling a choice lost command')
stable = GameSurfaces.build(commanded_hand(%w[A B], select_drawn: false))
stable.fields.first.index = 2
stable.update_spec(commanded_hand(%w[A B C], select_drawn: false))
assert(selected(stable) == 'Roll' && stable.take_cursor_announcement(0).nil?, 'Stable hand jumped from Roll on a draw')
stable = GameSurfaces.build(commanded_hand(%w[A B C D], select_drawn: false), state: stable.state)
assert(selected(stable) == 'Roll' && stable.take_cursor_announcement(0).nil?, 'Stable reconstruction jumped from Roll')
stable.fields.first.index = 1
stable.update_spec(commanded_hand(%w[A B C D E], select_drawn: false))
assert(selected(stable) == 'B' && stable.take_cursor_announcement(0).nil?, 'Stable draw changed the selected physical card')
stable.update_spec(commanded_hand(%w[A C D E F], select_drawn: false))
assert(selected(stable) == 'A', 'Removing the selected card no longer selected its predecessor')
stable.fields.first.index = stable.fields.first.options.length - 1
stable.update_spec(commanded_hand(%w[X Y], epoch: '2', select_drawn: false))
assert(selected(stable) == 'X', 'Stable selection leaked into a new deal')
puts 'PASS card-hand commands: action, IDs, cursor, sorting, default/stable draws, removal, empty hand, epoch, navigation, choices'
