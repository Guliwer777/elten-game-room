require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/mcr_kong_scoring'
include GameRoomTest::Assertions

tested = 0
(1..4).each do |kong_count|
  (0..kong_count).each do |closed_kongs|
    (0..4 - kong_count).each do |closed_pungs|
      kinds = [0, 9, 18, 27]
      melds = []
      concealed = [31, 31]
      kong_count.times { |index| melds << [:kong, kinds[index], index >= closed_kongs] }
      (4 - kong_count).times do |index|
        kind = kinds[kong_count + index]
        if index < closed_pungs
          concealed.concat([kind] * 3)
        else
          melds << [:pung, kind, true]
        end
      end
      form = GameRoomMahjong::MCRShapes.forms(concealed, melds: melds.map { |meld| meld.first(2) }).first
      raise 'The kong fixture is not a winning hand' unless form
      candidates = GameRoomMahjong::MCRPatterns.candidates(concealed: concealed, winning_tile: 31,
        form: form, melds: melds, self_draw: true)
      selected = GameRoomMahjong::MCRKongScoring.components(candidates)
      kong_points = case kong_count
      when 1 then closed_kongs == 1 ? 2 : 1
      when 2 then [4, 6, 8].fetch(closed_kongs)
      when 3 then 32
      when 4 then 88
      end
      concealed_count = closed_kongs + closed_pungs
      concealed_points = {0=>0, 1=>0, 2=>2, 3=>16, 4=>64}.fetch(concealed_count)
      concealed_points = 0 if kong_count == 2 && closed_kongs == 2 && closed_pungs == 0
      actual = selected.sum(&:points)
      assert_equal(kong_points + concealed_points, actual,
        "Wrong kong component: total kongs=#{kong_count}, closed kongs=#{closed_kongs}, closed pungs=#{closed_pungs}")
      assert_equal(1, selected.count { |fan| GameRoomMahjong::MCRKongScoring::KONG_IDS.include?(fan.id) })
      assert(selected.frozen? && selected.all?(&:frozen?))
      tested += 1
    end
  end
end
assert_equal(30, tested)
assert_raises(ArgumentError) { GameRoomMahjong::MCRKongScoring.components([Object.new]) }
puts 'PASS MCR kong component: 30 open/closed kong and concealed-pung combinations, single kong family, independent concealment and immutable outputs; not a complete hand score'
