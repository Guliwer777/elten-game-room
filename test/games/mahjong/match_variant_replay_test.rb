require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
include GameRoomTest::Assertions
include MahjongTableGameTest

[['riichi', 4], ['riichi', 3], ['hong_kong', 4]].each do |variant, seats|
  game = MahjongTableGameTest::Game.new
  repo = MahjongTableGameTest::Repository.new
  session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave].first(seats),
    'options'=>JSON.generate('variant'=>variant, 'seats'=>seats, 'match_winds'=>1)}
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: GameRoomRandom::SeededSource.new(137))
  events = []
  replay = game.replay(session, events, repo)
  ready_votes = 0
  until replay.finished?
    actor = game.active_actors(replay).first
    selection = game.automatic_action(replay, actor, context: context) || game.table_bot_selection(replay, actor)
    assert(selection, "Missing #{variant}/#{seats} action in #{replay.state[:phase]}")
    ready_votes += 1 if selection['action'] == 'ready'
    status, plan = game.action_for(selection, replay, actor, context: context)
    assert_equal(:ok, status)
    command = plan.events.first
    assert(command.value.bytesize <= 64)
    event = table_event(events.length + 1, command, actor: actor)
    events << event
    replay = game.incremental_replay(replay, session, [event], repo)
    assert_equal(events.length, replay.accepted_events.length)
    raise "#{variant}/#{seats} match failed to terminate" if events.length > 8000
  end
  match = replay.state[:match]
  assert_equal(seats, match.rotations)
  assert(match.hand_number >= seats)
  assert_equal((match.hand_number - 1) * seats, ready_votes)
  assert_equal(match.initial_points.sum, match.points.sum + match.sticks * 1000)
  cold = MahjongTableGameTest::Game.new.replay(session, events, repo)
  assert_equal(match.points, cold.state[:match].points)
  assert_equal(match.sticks, cold.state[:match].sticks)
  assert_equal(match.honba, cold.state[:match].honba)
  assert_equal(replay.winner, cold.winner)
  assert_equal(replay.draw, cold.draw)
  puts "PASS full #{variant}/#{seats} session: #{match.hand_number} hands, #{events.length} accepted events, dealer continuation and cold replay"
end
