require_relative '../../support/assertions'
require_relative '../../../games/bridge/rules'
include GameRoomTest::Assertions

# Independent arithmetic from WBF Laws 77 and 78 (printed pages 57-58):
# https://www.worldbridge.org/wp-content/uploads/2017/03/2017LawsofDuplicateBridge-nohighlights.pdf
# This does not certify the game's separate HCP reference as real duplicate.
def reference_duplicate(level, suit, doubles, vulnerable, won)
  missing = 6 + level - won
  if missing > 0
    return -missing * (vulnerable ? 100 : 50) if doubles.zero?
    first, later, extra = vulnerable ? [200, 300, 0] : [100, 200, 100]
    penalty = first + (missing - 1) * later + [missing - 3, 0].max * extra
    return -penalty * (doubles == 2 ? 2 : 1)
  end
  rate = %w[C D].include?(suit) ? 20 : 30
  tricks = (level * rate + (suit == 'N' ? 10 : 0)) * 2**doubles
  extra_rate = doubles.zero? ? rate : (vulnerable ? 200 : 100) * doubles
  game_bonus = tricks < 100 ? 50 : (vulnerable ? 500 : 300)
  slam = {6=>[500, 750], 7=>[1000, 1500]}.fetch(level, [0, 0])[vulnerable ? 1 : 0]
  tricks + (-missing) * extra_rate + game_bonus + [0, 50, 100][doubles] + slam
end

rules = GameRoomGames::BridgeRules
count = 0
(1..7).to_a.product(%w[C D H S N], [0, 1, 2], [false, true], (0..13).to_a).each do |level, suit, doubles, vulnerable, won|
  contract = rules::Contract.new(level:level, strain:suit, doubled:doubles, declarer:0)
  expected = reference_duplicate(level, suit, doubles, vulnerable, won)
  actual = rules.duplicate_score(contract, won, vulnerable:vulnerable)
  assert(actual == expected, "score #{level}#{suit}/#{doubles}/#{vulnerable}/#{won}: #{actual}, expected #{expected}")
  count += 1
end

lower_bounds = [0, 20, 50, 90, 130, 170, 220, 270, 320, 370, 430, 500,
  600, 750, 900, 1100, 1300, 1500, 1750, 2000, 2250, 2500, 3000, 3500, 4000]
(-10_000..10_000).step(10).each do |difference|
  band = lower_bounds.count { |lower| difference.abs >= lower } - 1
  expected = difference.negative? ? -band : band
  assert(rules.imps(difference) == expected, "IMP band #{difference}")
end

rubber = rules.new_rubber
[[0, 2, 'H', 8], [1, 1, 'N', 7], [0, 2, 'C', 8]].each do |seat, level, suit, won|
  contract = rules::Contract.new(level:level, strain:suit, doubled:0, declarer:seat)
  rules.score_rubber_deal(rubber, contract, won, hands:[[], [], [], []], honors:false)
end
assert(rubber[:games] == [1, 0] && rubber[:game_line] == [0, 0], 'a game did not clear both part scores')
assert(rules.rubber_totals(rubber) == [100, 40], 'clearing part scores destroyed cumulative points')
contract = rules::Contract.new(level:3, strain:'N', doubled:0, declarer:0)
rules.score_rubber_deal(rubber, contract, 9, hands:[[], [], [], []], honors:false)
assert(rules.rubber_finished?(rubber) && rubber[:rubber_bonus] == [0, 700], 'two-game rubber bonus missing')
assert(rules.rubber_totals(rubber) == [900, 40], 'rubber totals include a duplicate-style game bonus')
puts "PASS Bridge independent WBF arithmetic: #{count} contracts, 2001 signed IMP differences and cumulative rubber/game reset"
