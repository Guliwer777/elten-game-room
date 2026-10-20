require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
require_relative '../../support/mahjong_tiles'
require_relative '../../../lib/saved_games'
include GameRoomTest::Assertions
include MahjongTableGameTest
include MahjongTestTiles

class RiichiArchiveStorage
  def initialize; @data = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@data)); end
  def update_json(_path, default:); yield @data; end
end

# Fixed legal initial wall isolates archival correctness from finding a random
# opening ready hand. Real RiichiDeal.from_wall still validates/deals 136 tiles.
counts = Hash.new(0)
own = mahjong_kinds('123m456p789s1112z5z').map do |kind|
  tile = kind * 4 + counts[kind]
  counts[kind] += 1
  tile
end
rest = (0...136).to_a - own
hands = [own, rest.shift(13), rest.shift(13), rest.shift(13)]
wall = []
3.times { |batch| 4.times { |seat| wall.concat(hands[seat].slice(batch * 4, 4)) } }
cursors = [12] * 4
[0, 1, 2, 3, 0].each { |seat| wall << hands[seat][cursors[seat]]; cursors[seat] += 1 }
wall.concat(rest)
original = GameRoomMahjong::RiichiDeal.method(:shuffled)
GameRoomMahjong::RiichiDeal.define_singleton_method(:shuffled) do |seed:, seats: 4, dealer: 0|
  raise 'Unexpected fixture seed' unless seed == 0x0001020304050607 && seats == 4
  from_wall(wall, seats: seats, dealer: dealer)
end
begin
  game = MahjongTableGameTest::Game.new
  repo = MahjongTableGameTest::Repository.new
  session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave], 'options'=>JSON.generate('variant'=>'riichi', 'seats'=>4)}
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
  events = []
  replay = game.replay(session, events, repo)
  3.times do |index|
    actor = game.active_actors(replay).first
    selection = if index == 0
      game.automatic_action(replay, actor, context: context)
    elsif index == 1
      game.legal_actions(replay, actor).find { |action| action['question_id'].to_s.start_with?('mahjong-riichi:') && action['answer'] == replay.state[:round].flow.last_draw.to_s }
    else
      game.legal_actions(replay, actor).find { |action| action['answer'] == 'pass' }
    end
    status, plan = game.action_for(selection, replay, actor, context: context)
    assert_equal(:ok, status)
    event = table_event(index + 1, plan.events.first, actor: actor).merge('sequence'=>index + 1, 'created_at'=>1_800_000_000)
    events << event
    replay = game.incremental_replay(replay, session, [event], repo)
  end
  assert(replay.state[:round].pending_riichi)
  assert_equal(0, replay.state[:round].riichi_state.sticks)
  saves = SavedGames.new(RiichiArchiveStorage.new, owner: 'Alice')
  snapshot = Struct.new(:session, :events).new(session, events)
  row = saves.put(game: game, table: {'owner'=>'Alice', 'name'=>'Mahjong'}, snapshot: snapshot, repository: repo, now: 1_800_000_000)
  data = saves.restored_data(row, game: game, table_id: 99, now: 1_800_001_000)
  new_session = session.merge('id'=>99, 'players'=>data[:players])
  restored_events = data[:events]
  resumed = game.replay(new_session, restored_events, repo)
  assert_equal(round_snapshot(replay.state[:round]), round_snapshot(resumed.state[:round]))
  new_context = GameRoomGames::ActionContext.new(session_id: 99)
  while resumed.state[:round].pending_riichi
    actor = game.active_actors(resumed).first
    selection = game.legal_actions(resumed, actor).find { |action| action['answer'] == 'pass' }
    status, plan = game.action_for(selection, resumed, actor, context: new_context)
    assert_equal(:ok, status)
    number = restored_events.length + 1
    event = table_event(number, plan.events.first, actor: actor).merge('sequence'=>number, 'created_at'=>1_800_001_000)
    restored_events << event
    resumed = game.incremental_replay(resumed, new_session, [event], repo)
  end
  assert_equal(1, resumed.state[:round].riichi_state.sticks)
  assert_equal(29000, resumed.state[:round].riichi_state.points[0])
  assert_equal(-1000, game.participant_scores(resumed)['Alice'])
  fresh = game.replay(new_session, restored_events, repo)
  assert_equal(round_snapshot(resumed.state[:round]), round_snapshot(fresh.state[:round]))
  assert_equal(29000, fresh.state[:round].riichi_state.points[0], 'Cold replay must not charge the deposit twice')
ensure
  GameRoomMahjong::RiichiDeal.define_singleton_method(:shuffled, original)
end
puts 'PASS riichi archive: pending declaration restored before deposit, remaining responses accepted in fresh session, exactly one deposit after cold replay'
