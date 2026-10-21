require_relative '../support/tournament_presence_native'
P = TournamentPresenceNative

game = GameRoomGames::Farkle.new
options = game.normalize_options('score_limit'=>50, 'entry_minimum'=>0, 'turn_minimum'=>0, 'farkle_rules_version'=>2)
TournamentForfeitNative.with_fixture(game: game, users: %w[Alice Bob Carol Dave], options: options) do |f|
  f.start
  h = f.h
  clock = [0.0]
  runner = P.runner(f, 'Alice', clock)
  step(h, runner)
  context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new)
  roll = lambda do |actor, values|
    h.view(actor).next_random_values = values
    h.submit(actor, {'kind'=>'dice', 'action'=>'roll'}, context: context)
  end
  # Real native random receipts and legal actions, never a synthetic outcome.
  roll.call('Alice', [2, 3, 4, 6, 2, 3])
  assert_equal('Bob', h.replay('Alice').current_player)
  roll.call('Bob', [1, 1, 1, 1, 1, 1])
  h.submit('Bob', {'kind'=>'command', 'action'=>'keep', 'indices'=>'0,1,2,3,4,5'})
  h.submit('Bob', {'kind'=>'dice', 'action'=>'bank'})
  assert_equal(625, h.replay('Alice').state[:scores]['Bob'])
  # Current eliminations come only from the native cumulative absence limit,
  # not the removed organizer action that could interrupt an active game.
  %w[Bob Carol].each do |user|
    h.as(user) { h.view(user).leave }
    step(h, runner)
    20.times { clock[0] += 15; step(h, runner) }
    assert(h.game.eliminated_from_game?(h.replay('Alice'), user))
  end
  assert_equal('Dave', h.replay('Alice').current_player)
  roll.call('Dave', [1, 2, 3, 4, 6, 2])
  h.submit('Dave', {'kind'=>'command', 'action'=>'keep', 'indices'=>'0'})
  h.submit('Dave', {'kind'=>'dice', 'action'=>'bank'})
  replay = h.replay('Alice')
  assert(replay.finished?, 'Remaining players did not finish through normal rules')
  assert_equal('Dave', replay.winner)
  assert_equal(%w[Alice Bob Carol Dave], replay.players)
  assert_equal({'Alice'=>0, 'Bob'=>625, 'Carol'=>0, 'Dave'=>10}, replay.state[:scores])
  snapshot = P.snapshot(h)
  row = f.services['Alice'].instance_variable_get(:@bindings).fetch(h.table['__id'])
  captured = GameRoomTournaments::OrdinaryMatchResults.capture(registry: GameRoomGames::CATALOG,
    binding: row.first, session: snapshot.session, replay: replay, events: snapshot.events)
  assert_equal([['dave'], ['alice'], ['carol'], ['bob']], captured['summary']['places'],
    'An eliminated high score overrode the order established by play and eliminations')
  h.as('Alice') { f.services['Alice'].collect(row + [captured]) }
  count = f.documents.insert_count
  h.as('Alice') { f.services['Alice'].collect(row + [captured]) }
  assert_equal(count, f.documents.insert_count)
  cold = f.make_service('Carol')
  begin
    assert_equal(captured['summary'], h.as('Carol') { cold.result_view['results'].first['summary'] })
  ensure
    cold.close
  end
ensure
  runner&.close
end
puts 'PASS continued native game: real rolls and natural finish, preserved scores, eliminated leader last, one cold-readable result'
