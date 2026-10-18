require_relative '../../support/assertions'
require_relative '../../support/mahjong_match'
require_relative '../../../lib/saved_games'
include GameRoomTest::Assertions
include MahjongMatchFixture

class MahjongMatchArchiveStorage
  def initialize; @data = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@data)); end
  def update_json(_path, default:); yield @data; end
end

fixture = match_between_fixture
game, repo, session, context, events, replay = fixture.values_at(:game, :repo, :session, :context, :events, :replay)
choice = game.legal_actions(replay, 'Bob').first
status, plan = game.action_for(choice, replay, 'Bob', context: context)
assert_equal(:ok, status)
number = events.length + 1
event = table_event(number, plan.events.first, actor: 'Bob').merge('sequence'=>number, 'created_at'=>1_800_000_000)
events << event
replay = game.incremental_replay(replay, session, [event], repo)
assert_equal([1], replay.state[:ready_seats])
saves = SavedGames.new(MahjongMatchArchiveStorage.new, owner: 'Alice')
snapshot = Struct.new(:session, :events).new(session, events)
row = saves.put(game: game, table: {'owner'=>'Alice', 'name'=>'Mahjong'}, snapshot: snapshot, repository: repo, now: 1_800_000_000)
data = saves.restored_data(row, game: game, table_id: 99, now: 1_800_001_000)
new_session = session.merge('id'=>99, 'players'=>data[:players])
restored_events = data[:events]
resumed = game.replay(new_session, restored_events, repo)
assert_equal(:between_hands, resumed.state[:phase])
assert_equal(replay.state[:match].points, resumed.state[:match].points)
assert_equal(1, resumed.state[:match].hand_number)
assert_equal([1], resumed.state[:ready_seats])
assert_equal([], game.legal_actions(resumed, 'Bob'))
assert_equal(:stale, game.action_for(game.legal_actions(resumed, 'Alice').first, resumed, 'Alice', context: context).first)
new_context = GameRoomGames::ActionContext.new(session_id: 99, random_source: MahjongTableGameTest::RandomSource.new)
until resumed.state[:phase] == :awaiting_deal
  actor = game.active_actors(resumed).first
  choice = game.legal_actions(resumed, actor).first
  status, plan = game.action_for(choice, resumed, actor, context: new_context)
  assert_equal(:ok, status)
  number = restored_events.length + 1
  event = table_event(number, plan.events.first, actor: actor).merge('sequence'=>number, 'created_at'=>1_800_001_000)
  restored_events << event
  resumed = game.incremental_replay(resumed, new_session, [event], repo)
end
choice = game.automatic_action(resumed, 'Alice', context: new_context)
status, plan = game.action_for(choice, resumed, 'Alice', context: new_context)
assert_equal(:ok, status)
event = table_event(restored_events.length + 1, plan.events.first, actor: 'Alice')
next_hand = game.incremental_replay(resumed, new_session, [event], repo)
assert_equal(2, next_hand.state[:hand_number])
assert_equal(1, next_hand.state[:round].dealer)
assert_equal(resumed.state[:match].points, next_hand.state[:match].points, 'Starting the next hand must not apply the previous result again')
assert_equal([], next_hand.state[:ready_seats])
puts 'PASS full-match archive: cumulative points, dealer/wind/hand identity, partial readiness preserved, fresh-session votes and exactly one next deal'
