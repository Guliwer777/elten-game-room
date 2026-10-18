require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/tile_flow'
include GameRoomTest::Assertions

def all_pass(flow)
  peers = (0...flow.hands.length).to_a - [flow.seat]
  window = GameRoomMahjong::ClaimWindow.new(seats: flow.hands.length, discarder: flow.seat,
    tile_kind: GameRoomMahjong::Tiles.kind(flow.discards.last.last), generation: flow.generation,
    offers: peers.to_h { |seat| [seat, [[:pass]]] })
  assert_raises(ArgumentError) { flow.after_passes(window) }
  peers.each { |seat| window = window.respond(seat: seat, choice: [:pass], generation: flow.generation) }
  flow.after_passes(window)
end

[3, 4].each do |seats|
  tiles = GameRoomMahjong::Tiles.set(sanma: seats == 3)
  hands = seats.times.map { |index| tiles.slice(index * 13, 13) }
  wall = tiles.drop(seats * 13)
  initial = GameRoomMahjong::TileFlow.new(hands: hands, wall: wall, seat: seats - 1)
  hands.first.clear
  wall.clear
  assert_equal(13, initial.hands.first.length, 'Caller mutations must not change a snapshot')
  observer = initial.observation
  assert_equal([], observer[:concealed])
  assert(!observer.key?(:wall) && !observer.key?(:hands))
  assert_equal(initial.hands[0], initial.observation(viewer: 0)[:concealed])
  assert_raises(FrozenError) { initial.observation(viewer: 0)[:concealed] << 7 }
  current = initial
  draws = initial.wall.length
  draws.times do
    previous = current
    current = current.draw(seat: current.seat, generation: current.generation)
    assert_equal(:discard, current.phase)
    assert_equal(13, previous.hands[previous.seat].length)
    assert_equal(14, current.hands[current.seat].length)
    assert_raises(ArgumentError) { current.discard(seat: current.seat, tile: current.hands[current.seat].last, generation: previous.generation) }
    assert_raises(ArgumentError) { current.discard(seat: (current.seat + 1) % seats, tile: current.hands[current.seat].last, generation: current.generation) }
    assert_raises(ArgumentError) { current.discard(seat: current.seat, tile: 143, generation: current.generation) }
    current = current.discard(seat: current.seat, tile: current.hands[current.seat].last, generation: current.generation)
    assert_raises(ArgumentError) { current.draw(seat: current.seat, generation: current.generation) }
    current = all_pass(current)
    assert_equal((previous.seat + 1) % seats, current.seat)
    assert_equal(tiles.sort, (current.hands.flatten + current.wall + current.discards.map(&:last)).sort)
  end
  current = current.draw(seat: current.seat, generation: current.generation)
  assert_equal(:exhausted, current.phase)
  assert_equal(draws, current.discards.length)
  assert_raises(ArgumentError) { current.draw(seat: current.seat, generation: current.generation) }
  assert_raises(ArgumentError) { GameRoomMahjong::TileFlow.new(hands: initial.hands, wall: [initial.hands.first.first], seat: 0) }
end
puts 'PASS mahjong tile flow: three/four seats, immutable ownership, complete wall exhaustion, claim barrier, generations and private observations'
