require_relative '../../support/assertions'
require_relative '../../support/mahjong_game'
require_relative '../../../lib/saved_games'
include GameRoomTest::Assertions
include MahjongGameTest

class MahjongArchiveStorage
  def initialize; @data = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@data)); end
  def update_json(_path, default:); yield @data; end
end

game = MahjongGameTest::Game.new
repository = MahjongGameTest::Repository.new
session = {'id'=>45, 'players'=>['Alice'], 'options'=>JSON.generate('layout'=>'terraces')}
context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongGameTest::RandomSource.new)
events = []
replay = game.replay(session, events, repository)
3.times do
  selection = game.automatic_action(replay, 'Alice', context: context) || game.legal_actions(replay, 'Alice').first
  status, plan = game.action_for(selection, replay, 'Alice', context: context)
  assert_equal(:ok, status)
  command = plan.events.first
  assert(command.value.bytesize <= 64, 'Every persisted action must fit the transport and archive limit')
  event = mahjong_event(events.length + 1, command).merge('sequence'=>events.length + 1, 'created_at'=>1_800_000_000)
  events << event
  replay = game.incremental_replay(replay, session, [event], repository)
end
saves = SavedGames.new(MahjongArchiveStorage.new, owner: 'Alice')
snapshot = Struct.new(:session, :events).new(session, events)
row = saves.put(game: game, table: {'owner'=>'Alice', 'name'=>'Mahjong'}, snapshot: snapshot, repository: repository, now: 1_800_000_000)
restored = saves.restored_data(row, game: game, table_id: 99, now: 1_800_001_000)
new_session = session.merge('id'=>99, 'players'=>restored[:players])
resumed = game.replay(new_session, restored[:events], repository)
assert_equal(replay.state[:board].tiles, resumed.state[:board].tiles)
assert_equal(replay.state[:board].remaining, resumed.state[:board].remaining)
assert_equal(replay.state[:moves], resumed.state[:moves])
assert_equal(replay.state[:turn], resumed.state[:turn])
assert_equal(nil, game.incremental_replay(replay, new_session, [], repository))
new_context = GameRoomGames::ActionContext.new(session_id: 99)
assert_equal(:stale, game.action_for(game.legal_actions(resumed, 'Alice').first, resumed, 'Alice', context: context).first)
assert_equal(:ok, game.action_for(game.legal_actions(resumed, 'Alice').first, resumed, 'Alice', context: new_context).first)
status, undo = game.action_for({'kind'=>'command','action'=>'undo','turn'=>resumed.state[:turn]}, resumed, 'Alice', context: new_context)
assert_equal(:ok, status)
after_undo = game.incremental_replay(resumed, new_session, [mahjong_event(4, undo.events.first)], repository)
assert_equal(142, after_undo.state[:board].remaining.length)
puts 'PASS solitaire archive: shared save/restore, compact transport events, identical board, fresh session guards and undo after resume'
