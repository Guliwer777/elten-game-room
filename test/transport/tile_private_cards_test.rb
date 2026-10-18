require_relative '../support/private_card_games'
require_relative '../../games/domino'
require_relative '../../games/mexican_train'
$stdout.sync = true

cases = [
  [GameRoomGames::Domino, 3, {'score_limit'=>1}],
  [GameRoomGames::Domino, 4, {'score_limit'=>20, 'tile_set'=>'2d6', 'teams'=>true,
    'whole_team'=>true, 'allow_playable_draw'=>false, 'draw_until'=>true}, 2],
  [GameRoomGames::Domino, 2, {'score_limit'=>20, 'forbid_draw'=>true}],
  [GameRoomGames::MexicanTrain, 3, {'score_limit'=>1}]
]

cases.each do |klass, count, options, target_round|
  game = klass.new
  users = %w[Alice Bob Carol Dave].first(count)
  h, runners = PrivateCardGamesTest.create(game, users:users, options:options, random_values:Array.new(16, 8))
  replay = h.replay(users.first)
  assert(replay.state[:phase] == :playing, "#{game.id}: deal did not finish #{replay.state[:phase]}")
  if game.id == 'domino'
    priority = game.send(:active_players, replay.state)
    ranks = users.to_h do |user|
      cards = h.replay(user).state[:hands][user]
      doubles = cards.select { |tile| GameRoomDominoTiles.double?(tile) }
      value = doubles.empty? ? cards.map { |tile| GameRoomDominoTiles.pips(tile) }.max :
        100 + doubles.map { |tile| GameRoomDominoTiles.faces(tile).first }.max
      [user, value]
    end
    assert(replay.current_player == priority.max_by { |user| ranks[user] }, 'highest-double starter changed')
  end
  transfers = returns = false
  last_count = stalled = 0
  400.times do |index|
    PrivateCardGamesTest.tick(h, runners)
    PrivateCardGamesTest.assert_private(h)
    replay = h.replay(users.first)
    assert(replay.accepted_events.size == h.events(users.first).size,
      "#{game.id}: rejected events #{(h.events(users.first) - replay.accepted_events).inspect}; phase #{replay.state[:phase]}, effect #{replay.state[:private_effect].inspect}")
    stalled = replay.accepted_events.size == last_count ? stalled + 1 : 0
    last_count = replay.accepted_events.size
    assert(stalled < 8, "#{game.id}: stalled #{replay.state.inspect}")
    break if target_round && replay.state[:round] >= target_round && replay.state[:phase] == :playing && replay.state[:turn] > 2
    if replay.finished?
      assert(index > 0, 'empty game reported as finished')
      break
    end
    if index == 3
      owner = h.view(users.first)
      owner.transfer_ownership(owner.participants.find { |entry| entry.user == users.last })
      transfers = true
      next
    end
    if index == 5
      user = users[1]
      hand = h.replay(user).state[:hands][user].dup
      runners[user].close
      h.view(user).leave
      h.add_client(user)
      assert(h.join(user), 'return failed')
      runners[user] = runner_for(h, user)
      assert(h.replay(user).state[:hands][user] == hand, 'returned tile hand changed')
      returns = true
      next
    end
    actor = replay.current_player
    if actor
      mine = h.replay(actor)
      actions = game.legal_actions(mine, actor)
      if actions.any?
        choice = actions.max_by { |action| game.bot_action_score(mine, actor, action) }
        PrivateCardGamesTest.submit(h, runners, actor, choice)
      end
    end
    # The same ordinary surface entry point must also handle internal waits.
    h.users.each do |user|
      view = h.replay(user)
      spec = game.surface_spec(view, user)
      assert(spec, 'surface missing during private action')
      game.current_turn_shortcut_text(view, user)
    end
  end
  final = h.replay(users.first)
  assert(final.finished? || (target_round && final.state[:round] >= target_round && final.state[:phase] == :playing),
    "#{game.id}: unfinished #{final.state[:phase]}, #{final.accepted_events.size} events")
  assert(transfers && returns, 'missing lifecycle coverage')
  assert(final.accepted_events.size == h.events(users.first).size, 'valid move or proof rejected')
  puts "PASS #{game.id} #{count} players #{options}: #{final.accepted_events.size} events, round #{final.state[:round]}, finished #{final.finished?}, score #{final.state[:scores]}"
  runners.each_value(&:close)
end
