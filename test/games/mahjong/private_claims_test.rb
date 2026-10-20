require_relative '../../support/mahjong_private_pools'

# A concealed kong spanning the initial hand and a later receipt; Riichi must
# expose the next indicator without exposing any unused replacement tile.
%w[hong_kong riichi mcr].each do |variant|
  hand = [112,113,114,0,4,8,36,40,44,72,76,80,108]
  game, h, runners = MahjongPrivateTest.create(variant, hands: {'Alice'=>hand}, extra: 115)
  begin
    MahjongPrivateTest.submit(h, runners, 'Alice', answer: 28)
    users = h.users
    assert(users.all? { |user| h.replay(user).state[:round].flow.phase == :replacement }, 'kong did not await replacement')
    assert(users.all? { |user| h.replay(user).state[:round].flow.melds[0].first[:tiles].sort == [112,113,114,115] }, 'kong physical IDs differ')
    MahjongPrivateTest.submit(h, runners, 'Alice', command: 'replacement')
    users.each do |user|
      state = h.replay(user).state
      assert(!state[:private_error] && state[:phase] == :playing, 'replacement stalled')
      assert(state[:round].flow.draw_origin == :replacement, 'replacement origin lost')
      if variant == 'riichi'
        assert(state[:round].flow.reserve.size == 14, 'dead wall no longer fourteen tiles')
        assert(state[:round].flow.dora_indicators.size == 2, 'new dora indicator missing')
        assert(state[:round].flow.reserve.count { |tile| tile.is_a?(Integer) } == 2, 'hidden dead wall revealed')
      end
    end
    puts "PASS Mahjong private #{variant}: multi-receipt concealed kong and replacement"
  ensure
    runners.each_value(&:close)
  end
end

# A public discard gives two different players legal claims. Both claims are
# submitted through their own accounts; native arrival order cannot beat ron.
ready = [124,125,126,128,129,130,132,133,134,108,109,110,112]
carol = [114,115,0,4,8,36,40,44,72,76,80,116,120]
game, h, runners = MahjongPrivateTest.create('hong_kong', hands: {'Bob'=>ready, 'Carol'=>carol}, extra: 113)
begin
  MahjongPrivateTest.submit(h, runners, 'Alice', answer: 113)
  MahjongPrivateTest.submit(h, runners, 'Carol', answer: 'pung:28')
  assert(!h.replay('Alice').finished?, 'early pung committed before every response')
  MahjongPrivateTest.submit(h, runners, 'Bob', answer: 'win')
  MahjongPrivateTest.submit(h, runners, 'Dave', answer: 'pass')
  MahjongPrivateTest.settle(h, runners)
  finals = h.users.map { |user| h.replay(user) }
  assert(finals.all? { |replay| replay.finished? && replay.winner == 'Bob' && !replay.state[:private_error] },
    "discard-win audit failed #{finals.map { |replay| [replay.state[:phase], replay.state[:private_error]] }.inspect}")
  assert(finals.map { |replay| game.participant_scores(replay) }.uniq.one?, 'discard-win score mismatch')
  puts 'PASS Mahjong private discard win: higher-priority ron beats pung, all-account end audit'
ensure
  runners.each_value(&:close)
end
