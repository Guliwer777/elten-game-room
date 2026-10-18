require_relative '../support/native_room_harness'
require_relative '../support/private_archives'
require_relative '../../lib/account_saved_games'
require_relative '../../lib/presentation_replay'
require_relative '../../games/four_in_a_row'
require_relative '../../games/mancala'
require_relative '../../games/reversi'
require_relative '../../games/chess'
require_relative '../../games/checkers'

def play_next_board_move(h, random)
  snapshot = h.repositories.fetch(h.users.first).snapshot_for(h.session)
  h.instance_variable_set(:@session, snapshot.session)
  replay = h.game.replay(snapshot.session, snapshot.events, h.repositories.fetch(h.users.first))
  actor = replay.current_player
  assert(actor, 'board fixture unexpectedly finished')
  actions = h.game.legal_actions(replay, actor)
  h.submit(actor, actions.fetch(random.rand(actions.length)))
end

[GameRoomGames::FourInARow, GameRoomGames::Mancala, GameRoomGames::Reversi,
  GameRoomGames::Chess, GameRoomGames::Checkers].each do |type|
  game = type.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  h.add_client('Watcher')
  h.join('Watcher')
  h.as('Alice') { h.transports.fetch('Alice').set_observer(h.table, true, actor: 'Alice', subject: 'Watcher') }
  random = Random.new(7)
  4.times { play_next_board_move(h, random) }
  h.as('Alice') do
    h.transports.fetch('Alice').replace_game_player(h.table, session_id: h.session.fetch('__id'),
      player: 'Bob', replacement: 'Watcher')
  end
  2.times { play_next_board_move(h, random) }
  repository = h.repositories.fetch('Alice')
  snapshot = repository.snapshot_for(h.session)
  before = game.replay(snapshot.session, snapshot.events, repository)
  archive = AccountSavedGames.new(Object.new, owner: 'Alice', resources: PrivateArchiveDouble.new)
  row = archive.put(game: game, table: h.table, snapshot: snapshot, repository: repository, now: Time.now.to_i)
  restored_room = NativeRoomHarness.new(game: game, users: %w[Alice Watcher])
  data = archive.restored_data(row, game: game, table_id: restored_room.table.fetch('__id'))
  restored = restored_room.as('Alice') do
    restored_room.repositories.fetch('Alice').restore_session(table: restored_room.table,
      game: game.id, players: data.fetch(:players), options: row.fetch('options'), restore: data)
  end
  restored_room.instance_variable_set(:@session, restored)
  cache = GameRoomPresentationReplay.new(game, restored_room.repositories.fetch('Alice'))
  %w[Alice Watcher].each do |viewer|
    repo = restored_room.repositories.fetch(viewer)
    current = repo.snapshot_for(restored)
    replay = game.replay(current.session, current.events, repo)
    assert(replay.board == before.board && replay.current_player == before.current_player,
      "#{game.id}: restored board/turn changed")
    assert(replay.history.map(&:text) == before.history.map(&:text), "#{game.id}: historical names changed")
    cache = GameRoomPresentationReplay.new(game, repo)
    transitions = cache.transitions(current.session, replay, replay.accepted_events)
    replay.accepted_events.each_with_index do |event, index|
      expected = [game.replay(current.session, current.events.take(index), repo),
        game.replay(current.session, current.events.take(index + 1), repo)]
      assert(transitions.fetch(repo.event_id(event)).map(&:to_h) == expected.map(&:to_h),
        "#{game.id}: archived presentation lost an intermediate move")
    end
  end
  # An old roster change must not turn every later batch into full-history
  # replay. Count calls, without a timing benchmark or a machine-speed limit.
  repo = restored_room.repositories.fetch('Watcher')
  initial = repo.snapshot_for(restored)
  old_count = initial.events.length
  2.times { play_next_board_move(restored_room, random) }
  current = repo.snapshot_for(restored)
  final = game.replay(current.session, current.events, repo)
  original_replay = game.method(:replay)
  calls = []
  game.define_singleton_method(:replay) do |*args|
    calls << args[1].length
    original_replay.call(*args)
  end
  batch = final.accepted_events.drop(old_count)
  transitions = cache.transitions(current.session, final, batch)
  game.define_singleton_method(:replay, original_replay)
  assert(calls.empty?, "#{game.id}: later current-roster batch replayed whole history: #{calls.inspect}")
  batch.each_with_index do |event, offset|
    expected = [game.replay(current.session, current.events.take(old_count + offset), repo),
      game.replay(current.session, current.events.take(old_count + offset + 1), repo)]
    assert(transitions.fetch(repo.event_id(event)).map(&:to_h) == expected.map(&:to_h),
      "#{game.id}: continuing saved game lost a transition")
  end
  restored_room.assert_converged("#{game.id}: continued archived board")
end
puts 'Native board saves: five restored roster histories, subsequent legal moves and zero repeated full histories passed'
