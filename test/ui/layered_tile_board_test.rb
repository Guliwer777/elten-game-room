require_relative '../support/room_interface'
require_relative '../support/assertions'
include GameRoomTest::Assertions

def layered_spec(epoch: 1, editable: true)
  cells = [
    GameSurfaces::LayeredTileCell.new(id: '0', label: 'One: available from the left', match_key: 'one', selectable: true),
    GameSurfaces::LayeredTileCell.new(id: '1', label: 'Two: available from the right', match_key: 'two', selectable: true),
    GameSurfaces::LayeredTileCell.new(id: '2', label: 'One: available from the right', match_key: 'one', selectable: true)
  ]
  GameSurfaces::LayeredTileBoardSpec.new(header: 'Tiles', layers: [
    GameSurfaces::LayeredTileLayer.new(number: 1, cells: [cells]),
    GameSurfaces::LayeredTileLayer.new(number: 2, cells: [[nil]])], epoch: epoch, question_id: "pair:#{epoch}", editable: editable)
end

surface = GameSurfaces.build(layered_spec)
actions = []
surface.on_action { |action| actions << action }
grid = surface.fields.first
grid.trigger(:select, [0, 0])
assert(surface.cancel_pending_action? && actions.empty?, 'first tile was sent instead of marked locally')
grid.x = 1
grid.trigger(:select, [1, 0])
assert_equal([], actions)
assert_equal('0', surface.state['selected'])
assert(surface.cancel_pending_action! && !surface.cancel_pending_action?, 'cancel must clear the marked tile')
grid.x = 0
grid.trigger(:select, [0, 0])
surface.update_spec(layered_spec)
assert_equal('0', surface.state['selected'])
surface.update_spec(layered_spec(epoch: 2))
assert_equal(nil, surface.state['selected'])
grid.x = 0
grid.trigger(:select, [0, 0])
grid.x = 2
grid.trigger(:select, [2, 0])
assert_equal('0:2', actions.last.payload.fetch('answer'))
assert_equal('pair:2', actions.last.payload.fetch('question_id'))
surface.action_guard = -> { false }
grid.trigger(:select, [2, 0])
assert_equal(nil, surface.state['selected'])
surface.action_guard = nil
surface.handle_command('tile_layer', {'layer'=>2})
assert_equal([1, 1], [grid.width, grid.height])
grid.trigger(:select, [0, 0])
assert_equal(1, actions.length, 'empty position emitted a move')
assert(surface.handle_command('tile_coordinates'), 'coordinate command must be handled')
assert_equal(false, surface.handle_command('tile_layer', {'layer'=>3}))
surface.update_spec(layered_spec(epoch: 3, editable: false))
surface.handle_command('tile_layer', {'layer'=>1})
grid.trigger(:select, [0, 0])
assert(!surface.cancel_pending_action? && actions.length == 1, 'read-only board allowed selection')
assert(grid.equal?(surface.fields.first), 'updates replaced the board control')
puts 'PASS layered tile surface: local selection, cancellation, mismatch, stale epoch, guarded writes, layer resize, empty cells and read-only view'
