require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/claim_window'
include GameRoomTest::Assertions
window_class = GameRoomMahjong::ClaimWindow
offers = {1 => [[:chow, 0]], 2 => [[:pung, 2]], 3 => [[:win]]}
window = window_class.new(seats: 4, discarder: 0, tile_kind: 2, generation: 51, offers: offers)
assert_equal([1, 2, 3], window.pending)
with_chow = window.respond(seat: 1, choice: [:chow, 0], generation: 51)
assert_equal(nil, with_chow.resolution, 'A fast chow cannot bypass a pending win')
with_pung = with_chow.respond(seat: 2, choice: [:pung, 2], generation: 51)
complete = with_pung.respond(seat: 3, choice: [:win], generation: 51)
assert_equal(:win, complete.resolution.type)
assert_equal(3, complete.resolution.seat)
assert_equal([1, 2, 3], window.pending, 'A response must not mutate the previous replay snapshot')
assert_equal(complete, complete.respond(seat: 3, choice: [:win], generation: 51))
assert_raises(ArgumentError) { complete.respond(seat: 3, choice: [:pass], generation: 51) }
assert_raises(ArgumentError) { window.respond(seat: 0, choice: [:win], generation: 51) }
assert_raises(ArgumentError) { window.respond(seat: 1, choice: [:win], generation: 51) }
assert_raises(ArgumentError) { window.respond(seat: 1, choice: [:pass], generation: 50) }

window = window_class.new(seats: 4, discarder: 3, tile_kind: 27, generation: 1,
  offers: {0 => [[:win]], 1 => [[:win]], 2 => [[:win]]})
[2, 1, 0].each { |seat| window = window.respond(seat: seat, choice: [:win], generation: 1) }
assert_equal(0, window.resolution.seat, 'The nearest winner takes priority even when responding last')
window = window_class.new(seats: 3, discarder: 2, tile_kind: 30, generation: 1, offers: {0 => [], 1 => []})
[1, 0].each { |seat| window = window.respond(seat: seat, choice: [:pass], generation: 1) }
assert_equal(:passed, window.resolution.type)
assert_raises(ArgumentError) do
  window_class.new(seats: 3, discarder: 2, tile_kind: 2, generation: 1, offers: {0=>[[:chow,0]], 1=>[]})
end
assert_raises(ArgumentError) do
  window_class.new(seats: 4, discarder: 0, tile_kind: 2, generation: 1, offers: {1=>[], 2=>[[:chow,0]], 3=>[]})
end
assert_raises(ArgumentError) do
  window_class.new(seats: 4, discarder: 0, tile_kind: 2, generation: 1, offers: {1=>[], 2=>[[:pung,3]], 3=>[]})
end
puts 'PASS mahjong claim windows: all responses required, win/pung/chow priority, seat order, immutable snapshots and stale rejection'
