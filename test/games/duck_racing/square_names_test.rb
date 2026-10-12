require_relative '../../support/duck_game_adapter'

include GameRoomTest::Assertions

h = DuckGameAdapterTest::Harness.new
h.start
game, replay = h.game, h.replay
expected = [
  'On the line', 'Forest edge', 'Front pond', 'Left bank', 'Diving board',
  'South bank', "Ducklings' nest", 'Shady water', 'Reed path', 'In the pond',
  'Water lilies', 'On the water', 'Warm water', 'Cosy nest', 'On the water',
  'Whirlpool', 'In the pond', 'Deep water', 'Natural shelter', "Ducklings' nest",
  'Water lilies', 'North bank', 'Paddling pool', 'Off the water', 'Right bank',
  'Resupplying area', 'Sandbox', 'Wooden zone', 'Puddle of water', 'Finish line'
]
assert_equal(30, expected.size)
initial_state = Marshal.dump(replay.state)
expected.each_with_index do |name, index|
  square = index + 1
  assert_equal(name, game.square_name(square))
  description = game.square_text(replay, square)
  assert(description.start_with?("Square #{square}: #{name}. "), description)
  effects = GameRoomDuckRacing::Board::SQUARES.fetch(square)
  if effects.empty?
    assert(description.include?('No special effect.'))
  else
    effects.each { |effect| assert(description.include?(game.effect_text(effect))) }
  end
  history = []
  move = GameRoomDuckRacing::Board::Move.new(index, square, 1, false)
  game.send(:append_notices, history, [[:moved, 0, move], [:placed, 0, 'mine', square]], 100, replay.players)
  assert_equal("Alice lands on square #{square}. #{name}.", history[0].text)
  assert_equal(:scenery, history[1].kind)
  assert_equal("Alice leaves Mine on square #{square} (#{name}).", history[2].text)
end
assert_equal(initial_state, Marshal.dump(replay.state), 'Names must not change the race or its random state')
assert(game.racer_text(replay, 0).include?('square 1 (On the line)'))
assert_raises(ArgumentError) { game.square_name(0) }
assert_raises(ArgumentError) { game.square_name(31) }
puts 'PASS all 30 named Peaceful Pond squares preserve their effects and appear in positions and history'
