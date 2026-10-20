require_relative '../../support/mahjong_private_pools'

ready = [124,125,126,128,129,130,132,133,134,108,109,110,112]
game, h, runners = MahjongPrivateTest.create('riichi', hands: {'Alice'=>ready}, extra: 0,
  draws: {'Alice'=>[0,113]}, winds: 1)
begin
  replay = h.replay('Alice')
  declaration = game.legal_actions(replay, 'Alice').find do |selection|
    selection['question_id'].to_s.start_with?('mahjong-riichi:') && selection['answer'] == '0'
  end
  assert(declaration, 'declaration missing')
  PrivateCardGamesTest.submit(h, runners, 'Alice', declaration)
  MahjongPrivateTest.settle(h, runners)
  %w[Bob Carol Dave].each { |actor| MahjongPrivateTest.submit(h, runners, actor, answer: 'pass') }
  h.users.each do |user|
    ledger = h.replay(user).state[:round].riichi_state
    assert(ledger.levels.first == 2 && ledger.points.first == 29000, 'accepted declaration/deposit differs')
    assert(user == 'Alice' ? ledger.waits.first == [28] : ledger.waits.first.nil?, 'private wait list leaked')
  end
  %w[Bob Carol Dave].each do |actor|
    MahjongPrivateTest.submit(h, runners, actor, command: 'draw')
    tile = h.replay(actor).state[:round].flow.last_draw
    MahjongPrivateTest.submit(h, runners, actor, answer: tile)
    while (current = h.replay('Alice')).state[:round].flow.phase == :reactions
      player = current.current_player
      MahjongPrivateTest.submit(h, runners, player, answer: 'pass')
    end
  end
  MahjongPrivateTest.submit(h, runners, 'Alice', command: 'draw')
  before = h.replay('Alice')
  assert(before.state[:round].flow.last_draw == 113, 'wrong private winning draw')
  assert(before.state[:round].flow.reserve.count { |tile| tile.is_a?(Integer) } == 1, 'ura was exposed before winning')
  old_pool = before.state[:private_pool]
  MahjongPrivateTest.submit(h, runners, 'Alice', command: 'win')
  MahjongPrivateTest.settle(h, runners)
  finals = h.users.map { |user| h.replay(user) }
  assert(finals.all? { |item| item.state[:phase] == :between_hands && !item.state[:private_error] }, 'Riichi hand audit did not commit')
  assert(finals.map { |item| game.participant_scores(item) }.uniq.one?, 'match scores differ')
  assert(finals.first.state[:round].flow.reserve.count { |tile| tile.is_a?(Integer) } == 2, 'ura was not revealed on win')
  h.users.each { |user| MahjongPrivateTest.submit(h, runners, user, command: 'ready') }
  MahjongPrivateTest.settle(h, runners)
  current = h.replay('Alice')
  assert(current.state[:phase] == :playing && current.state[:hand_number] == 2, 'second private hand did not start')
  assert(current.state[:private_pool] != old_pool && !h.view('Alice').pool_data_store.key?(old_pool), 'old pool not retired')
  assert(h.users.all? { |user| !h.replay(user).state[:private_error] }, 'cold replay of retired pool failed')
  puts 'PASS Mahjong private Riichi: private waits, deposits, ura on win, audited match progression, ready barrier and fresh pool'
ensure
  runners.each_value(&:close)
end
