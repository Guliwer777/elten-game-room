require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/private_flow'
include GameRoomTest::Assertions

hands = Array.new(4) { |seat| (seat * 13...seat * 13 + 13).to_a }
[[[136,60,65,137], 65, [136,137]], [[136,137], nil, [136,137]], [[60,65], 60, []]].each do |wall, tile, flowers|
  public_flow = GameRoomMahjong::TileFlow.new(hands:hands,wall:wall,seat:0,replacement_source: :wall_back)
  opaque = Array.new(wall.size) { |index| "mahjong-wall:#{index}" }
  private_flow = GameRoomMahjong::PrivateTileFlow.new(hands:hands,wall:opaque,seat:0,replacement_source: :wall_back)
  expected = public_flow.draw(seat:0,generation:0)
  actual = private_flow.receive(tile,bonuses:flowers).draw(seat:0,generation:0)
  %i[hands flowers phase generation last_draw draw_origin].each do |field|
    assert_equal(expected.public_send(field),actual.public_send(field), "flower delivery changed #{field}")
  end
  assert_equal(expected.wall.size,actual.wall.size)
  assert_equal(opaque,private_flow.wall, 'incoming draw mutated an earlier snapshot')
end
assert_raises(ArgumentError) do
  GameRoomMahjong::TileFlow.new(hands:hands,wall:['mahjong-wall:0'],seat:0,replacement_source: :wall_back)
end
puts 'PASS Mahjong private flow: chained flowers, exhaustion on a flower, normal draw and unchanged ordinary strictness'
