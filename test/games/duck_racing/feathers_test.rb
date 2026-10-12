require_relative "../../support/assertions"
require_relative "../../../games/duck_racing_support/feathers"

include GameRoomTest::Assertions
feathers = GameRoomDuckRacing::Feathers
(1..10).each { |laps| assert_equal(laps * 6, feathers.starting(laps)) }
[0, -1, 1.5, "3", nil].each { |laps| assert_raises(ArgumentError) { feathers.starting(laps) } }
{0 => 1, 9 => 1, 10 => 2, 19 => 2, 20 => 3, 29 => 3, 30 => 4, 300 => 4}.each do |gap, turns|
  [-40, 0, 300].each do |last|
    assert_equal(turns, feathers.freeze_turns(progress: last + gap, last_progress: last, board_length: 30))
  end
end
assert_equal(2, feathers.freeze_turns(progress: 34, last_progress: 24, board_length: 30), "lap boundary lost distance")
assert_equal(4, feathers.freeze_turns(progress: 34, last_progress: 4, board_length: 30), "same square on different laps was tied")
assert_raises(ArgumentError) { feathers.freeze_turns(progress: 0, last_progress: 1, board_length: 30) }
assert_raises(ArgumentError) { feathers.freeze_turns(progress: 0, last_progress: 0, board_length: 0) }

racers = {
  "A" => {progress: 35, feathers: 0, frozen_turns: 0, hand: %w[first second]},
  "B" => {progress: 5, feathers: 0, frozen_turns: 0, hand: %w[third]},
  "bot" => {progress: 15, feathers: 2, frozen_turns: 0, hand: []}
}
assert_equal(%w[A B], feathers.start_freezes!(racers, board_length: 30))
assert_equal([4, 1, 0], racers.values.map { |racer| racer[:frozen_turns] })
assert_equal([], feathers.start_freezes!(racers, board_length: 30), "zero balance restarted an existing freeze")
racers["B"][:progress] = -100
assert_equal([], feathers.start_freezes!(racers, board_length: 30))
assert_equal(4, racers["A"][:frozen_turns], "a later gap changed a frozen duration")

assert_equal(:thawed, feathers.skip_frozen_turn!(racers["B"]))
assert_equal(5, racers["B"][:feathers])
assert_equal(nil, feathers.skip_frozen_turn!(racers["B"]))
assert_equal(5, racers["B"][:feathers], "thaw granted feathers twice")
racers["A"][:feathers] = 4 # A permitted quiz reward while frozen.
3.times { assert_equal(:frozen, feathers.skip_frozen_turn!(racers["A"])) }
assert_equal(:thawed, feathers.skip_frozen_turn!(racers["A"]))
assert_equal(9, racers["A"][:feathers], "thaw reset existing feathers instead of adding five")
assert_equal(%w[first second], racers["A"][:hand], "freeze altered the hand")
assert_equal(%w[third], racers["B"][:hand])
assert_equal(nil, feathers.skip_frozen_turn!(racers["bot"]))
assert_equal([], feathers.start_freezes!({}, board_length: 30))
puts "PASS Duck Racing starting feathers, freeze boundaries, existing rewards and single thaw"
