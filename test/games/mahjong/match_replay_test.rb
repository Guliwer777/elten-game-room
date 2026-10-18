require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
include GameRoomTest::Assertions
include MahjongTableGameTest

game = MahjongTableGameTest::Game.new
repo = MahjongTableGameTest::Repository.new
session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave], 'options'=>JSON.generate('variant'=>'mcr', 'seats'=>4, 'match_winds'=>1)}
random = MahjongTableGameTest::RandomSource.new
context = GameRoomGames::ActionContext.new(session_id: 45, random_source: random)
events = []
current = game.replay(session, events, repo)
old_selection = old_move = nil
ready_count = 0
steps = 0
until current.finished?
  actor = game.active_actors(current).first
  selection = game.automatic_action(current, actor, context: context) || game.table_bot_selection(current, actor)
  assert(selection, "No action in #{current.state[:phase]}")
  if current.state[:phase] == :playing && current.state[:hand_number] == 1
    old_selection ||= selection
  end
  if current.state[:phase] == :playing && current.state[:hand_number] == 2 && old_selection
    assert_equal(:stale, game.action_for(old_selection, current, actor, context: context).first)
    forged = old_move.merge('id'=>events.length + 1, 'actor'=>actor)
    assert_equal(events.length, game.incremental_replay(current, session, [forged], repo).accepted_events.length)
    old_selection = nil
  end
  if current.state[:phase] == :between_hands
    assert(!current.finished?, 'A hand win must not finish the whole match')
    assert_equal(current.state[:match].scores, session['players'].map { |player| game.participant_scores(current)[player] })
    ready_count += 1
  end
  status, plan = game.action_for(selection, current, actor, context: context)
  assert_equal(:ok, status)
  command = plan.events.first
  assert(command.value.bytesize <= 64)
  event = table_event(events.length + 1, command, actor: actor)
  old_move ||= event if command.action == 'mahjong_move'
  events << event
  previous = current
  current = game.incremental_replay(current, session, [event], repo)
  assert_equal(events.length, current.accepted_events.length)
  assert_equal(events.length - 1, previous.accepted_events.length)
  steps += 1
  raise 'Full Mahjong match did not finish' if steps > 2500
end
assert_equal(4, current.state[:hand_number])
assert_equal(4, current.state[:match].hand_number)
assert(current.state[:match].finished?)
assert_equal(12, ready_count)
assert_equal(4, random.calls)
assert_equal(0, game.participant_scores(current).values.sum)
assert_equal([], game.active_actors(current))
cold = MahjongTableGameTest::Game.new.replay(session, events, repo)
assert_equal(round_snapshot(current.state[:round]), round_snapshot(cold.state[:round]))
assert_equal(current.state[:match].points, cold.state[:match].points)
assert_equal(current.winner, cold.winner)
assert_equal(current.draw, cold.draw)
assert_equal(4, random.calls)
puts 'PASS full MCR session: four hands, all-seat ready barriers, fresh deals, scoped stale-input/event rejection, cumulative results and cold replay'
