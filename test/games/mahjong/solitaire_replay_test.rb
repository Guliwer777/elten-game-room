require_relative '../../support/assertions'
require_relative '../../support/mahjong_game'
require_relative '../../support/elten_array_shuffle'
include GameRoomTest::Assertions
include MahjongGameTest

game = MahjongGameTest::Game.new
repository = MahjongGameTest::Repository.new
session = {'id'=>45, 'players'=>['Alice'], 'options'=>JSON.generate('layout'=>'terraces')}
random = MahjongGameTest::RandomSource.new
context = GameRoomGames::ActionContext.new(session_id: 45, random_source: random)
initial = game.replay(session, [], repository)
assert_equal(:awaiting_deal, initial.state[:phase])
assert_equal(0, random.calls, 'Replaying must never consume fresh randomness')
selection = game.automatic_action(initial, 'Alice', context: context)
status, plan = game.action_for(selection, initial, 'Alice', context: context)
assert_equal(:ok, status)
events = [mahjong_event(1, plan.events.first)]
dealt = game.incremental_replay(initial, session, events, repository)
assert_equal(:playing, dealt.state[:phase])
assert_equal(144, dealt.state[:board].remaining.length)
assert_equal(1, random.calls)
seed = JSON.parse(events.first['value']).fetch('r')
solution = GameRoomMahjong::Solitaire.deal(seed: seed).solution
first, second = solution.first
selection = {'kind'=>'question', 'action'=>'submit', 'question_id'=>'mahjong-pairs:1', 'answer'=>"#{first}:#{second}"}
assert_equal(:not_your_turn, game.action_for(selection, dealt, 'Mallory', context: context).first)
foreign = GameRoomGames::ActionContext.new(session_id: 46, random_source: random)
assert_equal(:stale, game.action_for(selection, dealt, 'Alice', context: foreign).first)
status, plan = game.action_for(selection, dealt, 'Alice', context: context)
assert_equal(:ok, status)
move_event = mahjong_event(2, plan.events.first)
events << move_event
moved = game.incremental_replay(dealt, session, [move_event], repository)
assert_equal(142, moved.state[:board].remaining.length)
assert_equal(144, dealt.state[:board].remaining.length, 'Incremental replay must not change the displayed old snapshot')
assert_equal(1, game.participant_scores(moved).fetch('Alice'))
assert_equal(:invalid, game.action_for(selection, moved, 'Alice', context: context).first, 'A choice from an old question must be rejected')
status, plan = game.action_for({'kind'=>'command','action'=>'undo','turn'=>2}, moved, 'Alice', context: context)
assert_equal(:ok, status)
undo = mahjong_event(3, plan.events.first)
events << undo
restored = game.incremental_replay(moved, session, [undo], repository)
assert_equal(144, restored.state[:board].remaining.length)
assert_equal(3, restored.state[:turn], 'Undo must not roll back the event generation')
assert_equal(:invalid, game.action_for(selection, restored, 'Alice', context: context).first)
assert_equal(3, game.incremental_replay(restored, session, [move_event], repository).state[:turn], 'A repeated earlier event cannot replay a move after undo')
assert_equal(nil, game.incremental_replay(restored, session.merge('id'=>46), [], repository))
assert_equal(nil, game.incremental_replay(restored, session, [], MahjongGameTest::Repository.new))
assert_equal(nil, game.incremental_replay(restored, session.merge('options'=>JSON.generate('layout'=>'flat')), [], repository))
assert(!game.build_presentation_game.equal?(game), 'Presentation cannot share the mutable deal cache')

current = restored
solution.each do |left, right|
  selection = {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-pairs:#{current.state[:turn]}", 'answer'=>"#{left}:#{right}"}
  status, plan = game.action_for(selection, current, 'Alice', context: context)
  assert_equal(:ok, status)
  event = mahjong_event(events.length + 1, plan.events.first)
  events << event
  current = game.incremental_replay(current, session, [event], repository)
end
assert(current.finished?)
assert_equal('Alice', current.winner)
assert_equal(72, game.participant_scores(current).fetch('Alice'))
assert_equal(1, random.calls, 'Moves, undo and cold replay must preserve the original deal')
cold = game.replay(session, events, repository)
assert_equal(mahjong_snapshot(current.state), mahjong_snapshot(cold.state))
assert_equal(current.history.map(&:text), cold.history.map(&:text))
assert_equal([], game.legal_actions(current, 'Alice'))
assert_equal(:finished, game.action_for({'kind'=>'command','action'=>'undo','turn'=>current.state[:turn]}, current, 'Alice', context: context).first)

malformed = [
  {'v'=>1, 'action'=>'remove', 'turn'=>1, 'first'=>first.to_f, 'second'=>second},
  {'v'=>1, 'action'=>'remove', 'turn'=>1, 'first'=>-1, 'second'=>second},
  {'v'=>1, 'action'=>'remove', 'turn'=>1, 'first'=>first, 'second'=>second, 'seed'=>1},
  {'v'=>1, 'action'=>'remove', 'turn'=>1, 'first'=>first, 'second'=>first},
  {'v'=>1, 'action'=>'surrender', 'turn'=>0}
].each_with_index.map { |data,index| {'id'=>1000+index,'actor'=>'Alice','action'=>'mahjong','value'=>JSON.generate(data.transform_keys { |key| GameRoomGames::MahjongSolitaireGame::SOLITAIRE_EVENT_KEYS.fetch(key) })} }
assert_equal(mahjong_snapshot(dealt.state), mahjong_snapshot(game.replay(session, [events.first] + malformed, repository).state))
forged = move_event.merge('id'=>2000, 'actor'=>'Mallory')
assert_equal(mahjong_snapshot(dealt.state), mahjong_snapshot(game.replay(session, [events.first, forged], repository).state))
assert_raises(ArgumentError) { game.replay(session.merge('players'=>%w[Alice Bob]), [], repository) }
puts 'PASS solitaire session: full 72-pair game, action plans, incremental/cold replay, undo, stale/session/account guards and malformed-event rejection'
