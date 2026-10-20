require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
require_relative '../../../lib/saved_games'
include GameRoomTest::Assertions
include MahjongTableGameTest

class MahjongTableArchiveStorage
  def initialize; @data = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@data)); end
  def update_json(_path, default:); yield @data; end
end

[['mcr', 4], ['riichi', 4], ['riichi', 3], ['hong_kong', 4]].each do |variant, seats|
  game = MahjongTableGameTest::Game.new
  repository = MahjongTableGameTest::Repository.new
  players = %w[Alice Bob Carol Dave].first(seats)
  session = {'id'=>45, 'players'=>players, 'options'=>JSON.generate('variant'=>variant, 'seats'=>seats)}
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
  events = []
  replay = game.replay(session, events, repository)
  # Save while one response is already committed and the other peers still
  # have to respond to that exact discard, rather than only between turns.
  (3).times do
    actor = game.active_actors(replay).first
    selection = game.automatic_action(replay, actor, context: context) || game.table_bot_selection(replay, actor)
    status, plan = game.action_for(selection, replay, actor, context: context)
    assert_equal(:ok, status)
    event = table_event(events.length + 1, plan.events.first, actor: actor).merge('sequence'=>events.length + 1, 'created_at'=>1_800_000_000)
    events << event
    replay = game.incremental_replay(replay, session, [event], repository)
  end
  assert_equal(:reactions, replay.state[:round].flow.phase)
  assert_equal(1, replay.state[:round].window.responses.length)
  saves = SavedGames.new(MahjongTableArchiveStorage.new, owner: 'Alice')
  snapshot = Struct.new(:session, :events).new(session, events)
  row = saves.put(game: game, table: {'owner'=>'Alice', 'name'=>'Mahjong'}, snapshot: snapshot, repository: repository, now: 1_800_000_000)
  restored = saves.restored_data(row, game: game, table_id: 99, now: 1_800_001_000)
  new_session = session.merge('id'=>99, 'players'=>restored[:players])
  resumed = game.replay(new_session, restored[:events], repository)
  assert_equal(round_snapshot(replay.state[:round]), round_snapshot(resumed.state[:round]))
  assert_equal(replay.state[:round].window.pending, resumed.state[:round].window.pending)
  assert_equal(nil, game.incremental_replay(replay, new_session, [], repository))
  actor = game.active_actors(resumed).first
  selected = game.table_bot_selection(resumed, actor)
  assert_equal(:stale, game.action_for(selected, resumed, actor, context: context).first)
  new_context = GameRoomGames::ActionContext.new(session_id: 99)
  status, plan = game.action_for(selected, resumed, actor, context: new_context)
  assert_equal(:ok, status)
  event = table_event(4, plan.events.first, actor: actor)
  next_replay = game.incremental_replay(resumed, new_session, [event], repository)
  assert_equal(4, next_replay.accepted_events.length)
  assert_equal(1, resumed.state[:round].window.responses.length, 'Resuming must not mutate the archived claim window')
end
puts 'PASS Mahjong table archive: MCR/Riichi/sanma shared save/restore, in-progress claim responses, identical wall and private hands, fresh session actions'
