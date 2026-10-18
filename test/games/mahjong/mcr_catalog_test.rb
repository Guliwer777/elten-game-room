require_relative '../../support/assertions'
require_relative '../../support/mahjong_tiles'
require_relative '../../support/mahjong_mcr_cases'
require_relative '../../../games/mahjong_support/mcr_scoring'
include GameRoomTest::Assertions
include MahjongTestTiles

assert_equal((1..81).to_a - [43], MahjongMCRCases::CASES.map(&:first))
MahjongMCRCases::CASES.each do |id, text, winning, options|
  options ||= {}
  concealed = mahjong_kinds(text)
  tile = mahjong_kinds(winning).first
  melds = options.fetch(:melds, [])
  shapes = GameRoomMahjong::MCRShapes.forms(concealed, melds: melds.map { |meld| meld.first(2) })
  assert(!shapes.empty?, "Fan #{id} has an invalid fixture")
  found = shapes.flat_map do |form|
    GameRoomMahjong::MCRShapes.winning_locations(form, tile, melds.length, concealed: concealed).flat_map do |placement, wait|
      GameRoomMahjong::MCRPatterns.candidates(concealed: concealed, winning_tile: tile,
        form: form, placement: placement, wait: wait, **options)
    end
  end
  assert(found.any? { |fan| fan.id == id }, "Fan #{id} not detected in #{text}; detected: #{found.map(&:id).uniq.sort.inspect}")
end
puts 'PASS MCR candidate catalogue: explicit hand examples for all 80 structural/context/flower fan; Chicken Hand separately covered by scoring tests'
