require_relative '../../support/assertions'
require_relative '../../support/mahjong_game'
include GameRoomTest::Assertions
include MahjongGameTest

game = MahjongGameTest::Game.new
repository = MahjongGameTest::Repository.new
session = {'id'=>5, 'players'=>['Alice'], 'options'=>JSON.generate('layout'=>'terraces')}
context = GameRoomGames::ActionContext.new(session_id: 5, random_source: MahjongGameTest::RandomSource.new)
initial = game.replay(session, [], repository)
assert_equal(:information, game.surface_spec(initial, 'Alice').mode)
_, plan = game.action_for(game.automatic_action(initial, 'Alice'), initial, 'Alice', context: context)
event = mahjong_event(1, plan.events.first)
replay = game.incremental_replay(initial, session, [event], repository)
spec = game.surface_spec(replay, 'Alice')
board = spec.parts.find { |part| part.id == 'board' }.surface
commands = spec.parts.find { |part| part.id == 'commands' }.surface
assert(spec.parts.none? { |part| part.id == 'pairs' }, 'The UI must not offer pre-matched pairs')
assert(board.is_a?(GameSurfaces::LayeredTileBoardSpec))
assert_equal([1, 2, 3], board.layers.map(&:number))
assert_equal(144, board.layers.flat_map { |layer| layer.cells.flatten }.compact.length)
assert_equal(['surrender'], commands.commands.map(&:id))
board.layers.flat_map { |layer| layer.cells.flatten }.compact.each do |item|
  slot = Integer(item.id)
  assert(item.label.encoding == Encoding::UTF_8 && item.label.valid_encoding?)
  next unless replay.state[:board].covered?(slot)
  assert_equal('Covered tile', item.label, 'Covered faces must not be exposed')
  assert_equal(nil, item.match_key)
  assert_equal(false, item.selectable)
end
first, second = replay.state[:board].pairs.first
selection = {'kind'=>'question', 'action'=>'submit', 'question_id'=>board.question_id, 'answer'=>"#{first}:#{second}"}
status, plan = game.action_for(selection, replay, 'Alice', context: context)
assert_equal(:ok, status)
moved = game.incremental_replay(replay, session, [mahjong_event(2, plan.events.first)], repository)
next_spec = game.surface_spec(moved, 'Alice')
next_commands = next_spec.parts.find { |part| part.id == 'commands' }.surface.commands
assert_equal(['undo', 'surrender'], next_commands.map(&:id))
assert_equal(2, next_commands.first.payload.fetch('turn'))
assert_equal(:invalid, game.action_for(selection, moved, 'Alice', context: context).first)
spectator = game.surface_spec(moved, 'Bob')
assert(spectator.parts.none? { |part| part.id == 'commands' })
assert_equal(false, spectator.parts.find { |part| part.id == 'board' }.surface.editable)
assert(spectator.parts.select { |part| part.surface.is_a?(GameSurfaces::QuestionSpec) }.all? { |part| part.surface.read_only })
%w[tiles pairs].each do |text|
  assert(next_spec.parts.last.surface.value.include?(text), 'Progress must describe pairs and remaining tiles')
end
assert_equal(%w[1 2 3 d], game.custom_game_shortcuts(replay, 'Alice').map(&:key))
puts 'PASS solitaire presentation: manual layered board, no pair hints, covered faces, layer shortcuts, spectators, undo and stale choices'
