require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_game'
include GameRoomTest::Assertions
include MahjongGameTest

NativeOptionTest.native_method(GridBox, :update, 'src/ui/controls/grid_box.rb')
NativeOptionTest.native_method(Button, :press, 'src/ui/controls/button.rb')

def grid_tap(grid, code)
  [[code], []].each do |held|
    raw = "\0" * 256
    held.each { |key| raw.setbyte(key, 0x80) }
    $mahjong_grid_frame = $mahjong_grid_frame.to_i + 1
    EltenAPI::KeyboardState.update(raw_state: raw, events: [[code, !held.empty?]], now: $mahjong_grid_frame * 0.1,
      pressed_implies_held: false, synthesize_repeats: false)
    $input_frame_serial = $input_frame_serial.to_i + 1
    $keyboard_state_frame_serial = $input_frame_serial
    $keyboard_state_frame_thread = Thread.current
    $activecontrols = []
    grid.update
  end
end

def move_to_slot(surface, board, slot)
  position = board.positions.fetch(slot)
  surface.handle_command('tile_layer', {'layer'=>position.level + 1})
  layer = board.positions.select { |item| item.level == position.level }
  surface.fields.first.set_logical_position(layer.map(&:x).uniq.sort.index(position.x), layer.map(&:y).uniq.sort.index(position.y))
end

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = MahjongGameTest::Game.new
  book = game.rule_book
  assert_equal(%i[aim tiles play ending layout controls], book.sections.map(&:id))
  book.sections.each do |section|
    assert(section.title.encoding == Encoding::UTF_8 && section.title.valid_encoding?)
    section.paragraphs.each { |text| assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?) }
  end
  if language == 'pl'
    assert_equal('Pasjans — pojęcia i cel', book.sections.first.title)
    assert(book.sections.last.paragraphs.any? { |text| text.include?('Enter') })
  end
  repository = MahjongGameTest::Repository.new
  session = {'id'=>9, 'players'=>['Alice'], 'options'=>JSON.generate('layout'=>'terraces')}
  context = GameRoomGames::ActionContext.new(session_id: 9, random_source: MahjongGameTest::RandomSource.new)
  initial = game.replay(session, [], repository)
  _, plan = game.action_for(game.automatic_action(initial, 'Alice'), initial, 'Alice', context: context)
  dealt = game.incremental_replay(initial, session, [mahjong_event(1, plan.events.first)], repository)
  surface = GameSurfaces.build(game.surface_spec(dealt, 'Alice'))
  actions = []
  surface.on_action { |action| actions << action }
  grid = surface.fields.first
  assert(grid.is_a?(GameSurfaces::LayeredTileGrid))
  assert_equal(3, surface.fields.length, 'Board, end button and progress should use three controls')
  grid_tap(grid, 0x27)
  grid_tap(grid, 0x28)
  assert_equal([1, 1], [grid.x, grid.y], 'Native arrows must move columns and rows independently')
  assert_equal([], actions, 'Arrow movement must not remove a pair')
  model = dealt.state[:board]
  covered = model.remaining.find { |slot| model.covered?(slot) }
  move_to_slot(surface, model, covered)
  grid_tap(grid, 0x0D)
  assert_equal([], actions, 'A covered tile must not become a selection')
  first, second = model.pairs.first
  move_to_slot(surface, model, first)
  grid_tap(grid, 0x0D)
  assert_equal([], actions, 'The first selection is local only')
  assert_equal(first.to_s, surface.state['parts']['board']['selected'])
  mismatch = model.free_slots.find { |slot| slot != first && !GameRoomMahjong::Tiles.match?(model.tiles[first], model.tiles[slot]) }
  if mismatch
    move_to_slot(surface, model, mismatch)
    grid_tap(grid, 0x0D)
    assert_equal([], actions, 'Mismatched tiles must not produce a write')
  end
  move_to_slot(surface, model, second)
  surface.handle_command('tile_coordinates')
  assert(NativeOptionUI.spoken.last.start_with?('Warstwa '), 'Coordinate speech must use Polish labels') if language == 'pl'
  grid_tap(grid, 0x0D)
  assert_equal(1, actions.length, 'Second matching tile must produce one removal')
  assert_equal('board', actions.first.source)
  status, plan = game.action_for(actions.first.to_h, dealt, 'Alice', context: context)
  assert_equal(:ok, status)
  moved = game.incremental_replay(dealt, session, [mahjong_event(2, plan.events.first)], repository)
  new_surface = GameSurfaces.reconcile(game.surface_spec(moved, 'Alice'), previous: surface, state: surface.state)
  assert(new_surface.fields.first.equal?(grid), 'Refresh must preserve the native board control')
  assert_equal(nil, new_surface.state['parts']['board']['selected'])
  new_actions = []
  new_surface.on_action { |action| new_actions << action }
  undo_label = GameRoomContent.utf8(GameRoomLocalization.translate('Undo the last pair'))
  undo = new_surface.fields.find { |field| field.is_a?(Button) && field.label == undo_label }
  assert(undo, 'Native undo button must appear after removing a pair')
  undo.press
  assert_equal('undo', new_actions.first.name)
  assert_equal(2, new_actions.first.payload.fetch('turn'))
  assert_equal(:invalid, game.action_for(actions.first.to_h, moved, 'Alice', context: context).first,
    'An old native list action must remain stale after the surrounding view is refreshed')
  spectator = GameSurfaces.build(game.surface_spec(moved, 'Bob'))
  spectator_actions = []
  spectator.on_action { |action| spectator_actions << action }
  assert(spectator.fields.none? { |field| field.is_a?(Button) })
  move_to_slot(spectator, moved.state[:board], moved.state[:board].free_slots.first)
  grid_tap(spectator.fields.first, 0x0D)
  assert_equal([], spectator_actions, 'A spectator cannot activate board entries')
end
puts 'PASS native manual Solitaire EN/PL/CS/ES/RU: real grid arrows/Enter, covered tiles, two-tile selection, mismatch, layers, coordinates, reuse, undo and spectators'
