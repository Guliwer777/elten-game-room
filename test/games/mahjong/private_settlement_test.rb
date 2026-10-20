require_relative '../../support/mahjong_private_pools'

%w[hong_kong riichi mcr].each do |variant|
  game = GameRoomGames::Mahjong.new
  users = %w[Alice Bob Carol Dave]
  marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'mahjong-audit'},
    'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
  options = game.normalize_options('variant'=>variant, 'hong_kong_winds'=>'0', 'riichi_winds'=>'0', 'mcr_winds'=>'0', 'bot_delay'=>0)
  h = NativeRoomHarness.new(game: game, users: users, tournament: marker, options: options)
  ready = [124,125,126,128,129,130,132,133,134,108,109,110,112]
  extra, indicator = 113, 116
  deck = GameRoomMahjong::Tiles.set(bonuses: variant != 'riichi')
  others = (deck - ready - [extra, indicator]).select { |tile| tile < 136 }.first(39)
  prefix = ready + others + (variant == 'riichi' ? [indicator] : []) + [extra]
  order = (prefix + (deck - prefix)).map { |tile| deck.index(tile) + 1 }
  h.core.instance_variable_set(:@mahjong_test_pool_order, order)
  h.core.instance_variable_set(:@mahjong_fixture, {ready: ready.map { |tile| deck.index(tile) + 1 },
    extra: deck.index(extra) + 1, indicator: deck.index(indicator) + 1})
  h.start
  runners = users.to_h { |user| [user, runner_for(h, user)] }
  begin
    20.times { PrivateCardGamesTest.tick(h, runners) }
    replay = h.replay('Alice')
    assert(replay.state[:phase] == :playing, 'opening stalled')
    win = game.legal_actions(replay, 'Alice').find { |action| action['action'] == 'win' }
    assert(win, "#{variant}: legal win missing #{replay.state[:hands]['Alice'].inspect}; flow=#{[replay.state[:round].flow.phase, replay.state[:round].flow.last_draw].inspect}")
    PrivateCardGamesTest.submit(h, runners, 'Alice', win)
    30.times do
      PrivateCardGamesTest.tick(h, runners)
      break if h.replay('Alice').finished? || h.replay('Alice').state[:private_error]
    end
    final = users.map { |user| h.replay(user) }
    assert(final.all?(&:finished?), "#{variant}: finish stalled #{final.map { |item| [item.state[:phase], item.state[:private_error]] }.inspect}")
    assert(final.all? { |item| item.winner == 'Alice' }, 'wrong audited winner')
    assert(final.all? { |item| !item.state[:private_error] && item.accepted_events.size == h.events('Alice').size }, 'audit lost accepted receipts')
    scores = final.map { |item| game.participant_scores(item) }
    assert(scores.uniq.one? && scores.first.values.sum.zero?, 'audited scores diverged')
    puts "PASS Mahjong private #{variant}: proved self-draw, all-account disclosure and strict scoring audit"
  ensure
    runners.each_value(&:close)
  end
end
