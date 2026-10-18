require_relative '../support/native_room_harness'
require_relative '../../lib/presentation_replay'
require_relative '../../lib/game_sounds'
require_relative '../../games/four_in_a_row'
require_relative '../../games/mancala'
require_relative '../../games/reversi'
require_relative '../../games/chess'
require_relative '../../games/checkers'

[GameRoomGames::FourInARow, GameRoomGames::Mancala, GameRoomGames::Reversi,
  GameRoomGames::Chess, GameRoomGames::Checkers].each do |type|
  game = type.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  h.add_client('Watcher')
  h.join('Watcher')
  h.as('Alice') { h.transports.fetch('Alice').set_observer(h.table, true, actor: 'Alice', subject: 'Watcher') }
  h.users.each do |user|
    assert(h.repositories.fetch(user).snapshot_for(h.session).events.empty?, 'unexpected initial game event')
  end
  random = Random.new(7)
  play = lambda do
    state = h.replay('Alice')
    actor = state.current_player
    assert(actor, "#{game.id}: fixture ended before replacement")
    actions = game.legal_actions(state, actor)
    h.submit(actor, actions.fetch(random.rand(actions.length)))
  end
  4.times { play.call }
  previous = h.events('Alice').dup
  h.as('Alice') do
    h.transports.fetch('Alice').replace_game_player(h.table, session_id: h.session.fetch('__id'),
      player: 'Bob', replacement: 'Watcher')
  end
  h.instance_variable_set(:@session, h.repositories.fetch('Alice').snapshot_for(h.session).session)
  2.times { play.call }
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |person| person.user == 'Watcher' })
  h.assert_converged("#{game.id}: replacement and host transfer")
  %w[Alice Bob Watcher].each do |viewer|
    repo = h.repositories.fetch(viewer)
    snapshot = repo.snapshot_for(h.session)
    assert(snapshot.session.fetch('__players') == %w[Alice Watcher], 'native roster did not change')
    assert(snapshot.events.take(previous.length) == previous, 'replacement changed stored events')
    final = game.replay(snapshot.session, snapshot.events, repo)
    assert(final.accepted_events.length == 6, 'replacement rejected a legal board move')
    cache = GameRoomPresentationReplay.new(game, repo)
    transitions = cache.transitions(snapshot.session, final, final.accepted_events)
    final.accepted_events.each_with_index do |event, index|
      expected = [game.replay(snapshot.session, snapshot.events.take(index), repo),
        game.replay(snapshot.session, snapshot.events.take(index + 1), repo)]
      assert(transitions.fetch(repo.event_id(event)).map(&:to_h) == expected.map(&:to_h),
        "#{game.id}: #{viewer} lost an intermediate historical move after native replacement")
    end
  end
end
puts 'Native board presentation: five games, actual participant replacement, host transfer and three clients passed'
