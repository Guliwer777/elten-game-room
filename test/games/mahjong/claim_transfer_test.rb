require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/claim_offers'
include GameRoomTest::Assertions

def discard_fixture(reserve: [])
  hands = [[16] + (80..92).to_a, [8, 12, 20, 24] + (40..48).to_a,
           [17, 18, 19] + (52..61).to_a, (64..76).to_a]
  flow = GameRoomMahjong::TileFlow.new(hands: hands, wall: [96, 97], reserve: reserve, seat: 0, phase: :discard)
  flow.discard(seat: 0, tile: 16, generation: 0)
end

def resolved(flow, claimant, choice)
  window = GameRoomMahjong::ClaimOffers.for_discard(flow, replacement_available: true)
  window.pending.each do |seat|
    window = window.respond(seat: seat, choice: seat == claimant ? choice : [:pass], generation: flow.generation)
  end
  window
end

def physical_tiles(flow)
  (flow.hands.flatten + flow.wall + flow.reserve + flow.discards.map(&:last) + flow.melds.flatten(1).flat_map { |meld| meld[:tiles] }).sort
end

{chow: [1, 2], pung: [2, 4], kong: [2, 4]}.each do |type, (seat, first)|
  before = discard_fixture(reserve: [100, 101])
  window = resolved(before, seat, [type, first])
  after = before.apply_claim(window)
  assert_equal(physical_tiles(before), physical_tiles(after), 'Claim must transfer the exact physical discard without loss or duplication')
  assert_equal(13, before.hands[seat].length)
  assert_equal([], before.melds[seat])
  assert_equal([], after.discards)
  assert_equal(seat, after.seat)
  assert_equal(type, after.melds[seat].first[:type])
  assert_equal(0, after.melds[seat].first[:from])
  assert(after.melds[seat].first[:tiles].include?(16))
  assert_raises(ArgumentError) { after.apply_claim(window) }
  assert_raises(ArgumentError) { after.draw(seat: seat, generation: after.generation) }
  if type == :kong
    assert_equal(:replacement, after.phase)
    assert_equal(10, after.hands[seat].length)
    ready = after.draw_replacement(seat: seat, generation: after.generation)
    assert_equal(:discard, ready.phase)
    assert_equal(11, ready.hands[seat].length)
    assert(ready.hands[seat].include?(100))
    assert_equal([101], ready.reserve)
    assert_equal([96, 97], ready.wall, 'Kong replacement must not silently use the normal draw wall')
    assert_equal(physical_tiles(before), physical_tiles(ready))
    assert_raises(ArgumentError) { ready.draw_replacement(seat: seat, generation: ready.generation) }
  else
    assert_equal(:discard, after.phase)
    assert_equal(11, after.hands[seat].length)
    ready = after
  end
  next_turn = ready.discard(seat: seat, tile: ready.hands[seat].first, generation: ready.generation)
  assert_equal(10, next_turn.hands[seat].length)
  assert_equal(:reactions, next_turn.phase)
  assert_raises(FrozenError) { next_turn.observation[:melds][seat].first[:tiles] << 99 }
end
without_reserve = discard_fixture
assert_raises(ArgumentError) { without_reserve.apply_claim(resolved(without_reserve, 2, [:kong, 4])) }
assert_equal(13, without_reserve.hands[2].length)

# A forged offer is not evidence that the claimant owns the required copies.
fake = GameRoomMahjong::ClaimWindow.new(seats: 4, discarder: 0, tile_kind: 4,
  generation: without_reserve.generation, offers: {1=>[[:pung, 4]], 2=>[[:pass]], 3=>[[:pass]]},
  responses: {1=>[:pung, 4], 2=>[:pass], 3=>[:pass]})
assert_raises(ArgumentError) { without_reserve.apply_claim(fake) }
puts 'PASS mahjong claim transfer: exact physical chow/pung/kong, immutable exposed sets, replacement wall, stale/forged claims and next discard'
