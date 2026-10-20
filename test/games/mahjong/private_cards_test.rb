require_relative '../../support/private_card_games'
require_relative '../../../games/mahjong'

game = GameRoomGames::Mahjong.new
%w[hong_kong riichi mcr].each do |variant|
  users = %w[Alice Bob Carol Dave]
  h, runners = PrivateCardGamesTest.create(game, users: users,
    options: {'variant'=>variant, 'match_winds'=>0})
  begin
    30.times { PrivateCardGamesTest.tick(h, runners) }
    replay = h.replay(users.first)
    assert(replay.state[:phase] == :playing, "#{variant}: setup stalled #{replay.state[:phase]}, #{replay.state[:private_error]}")
    users.each do |user|
      state = h.replay(user).state
      assert(state[:hands][user].all? { |tile| tile.is_a?(Integer) && tile < 136 }, 'own hand missing')
      (users - [user]).each do |other|
        assert(state[:hands][other].all? { |tile| GameRoomPrivateCardLedger.hidden?(tile) }, 'concealed hand leaked')
        id, draw = state[:private_draws].find { |_, item| item[:player] == other }
        assert_raises(EltenLink::Error) { h.view(user).pool(draw[:pool]).draw(id) }
      end
      assert(state[:round].flow.wall.all? { |tile| tile.is_a?(String) }, 'future wall leaked')
      assert(game.game_view_spec(h.replay(user), user).surface, 'private surface missing')
      assert(game.game_shortcuts(h.replay(user), user), 'private shortcuts missing')
    end
    12.times do
      current = h.replay(users.first)
      actor = current.current_player
      mine = h.replay(actor)
      action = game.legal_actions(mine, actor).find { |selection| selection['answer'] == 'pass' } || game.legal_actions(mine, actor).first
      assert(action, "#{variant}: no move for #{actor}, #{mine.state[:phase]}")
      PrivateCardGamesTest.submit(h, runners, actor, action)
      3.times { PrivateCardGamesTest.tick(h, runners) }
      assert(!h.replay(actor).state[:private_error], 'private replay error')
    end
    assert(h.events(users.first).size == h.replay(users.first).accepted_events.size, 'wire action lost')
    assert(h.events(users.first).none? { |event| event['__server_random'] }, 'public seed leaked')
    puts "PASS Mahjong private #{variant}: real runner, own hands, foreign denial, hidden wall and continued play"
  ensure
    runners.each_value(&:close)
  end
end
