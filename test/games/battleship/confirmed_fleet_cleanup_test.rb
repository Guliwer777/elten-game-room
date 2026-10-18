require_relative '../../support/session_runner'
require_relative '../../support/hidden_submission_files'
require_relative '../../../games/battleship'

Dir.mktmpdir('battleship-confirmed-cleanup-') do |directory|
  game = GameRoomGames::Battleship.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  programs = h.users.to_h { |user| [user, HiddenSubmissionFiles.new(File.join(directory, user))] }
  vaults = programs.transform_values { |program| HiddenSubmissions::Vault.new(program.storage) }
  contexts = h.users.to_h do |user|
    [user, GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
      hidden_submissions: vaults.fetch(user))]
  end
  runners = h.users.to_h do |user|
    runner = runner_for(h, user)
    runner.instance_variable_get(:@context_template).hidden_submissions = vaults.fetch(user)
    [user, runner]
  end
  stored = ->(user, session_id = h.session['__id']) do
    HiddenSubmissions::Vault.new(HiddenSubmissions::ProgramStorage.new(programs.fetch(user)))
      .reveal(session_id: session_id, round_id: 'fleet', user: user)
  end
  begin
    h.submit('Alice', context: contexts.fetch('Alice'))
    ships = [[0, 1, 2, 3], [20, 21, 22], [40, 41, 42], [60, 61], [80, 81], [85, 86], [8], [28], [48], [68]]
    h.users.each do |user|
      h.submit(user, {'kind' => 'command', 'action' => 'seal', 'ships' => JSON.generate(ships)}, context: contexts.fetch(user))
      step(h, runners.fetch(user), user)
    end
    assert(h.users.all? { |user| stored.call(user) }, 'An active game lost its sealed fleet')
    h.users.each do |user|
      cold = game.build_session_game
      cold.prepare_view(h.replay(user), user, context: contexts.fetch(user))
      cells = cold.surface_spec(h.replay(user), user).parts.last.surface.cells.flatten
      assert(cells.count { |cell| cell.include?('ship') } == 20, 'Cold active rejoin lost its private fleet')
    end
    assert(!game.supports_saved_games?, 'Fleet cleanup must not add unsupported saved games')

    misses = (0...100).to_a - ships.flatten
    ships.flatten.each_with_index do |cell, index|
      if index.positive?
        miss = misses.shift
        h.submit('Bob', {'kind' => 'grid', 'action' => 'select', 'x' => miss % 10, 'y' => miss / 10})
        h.submit('Alice', context: contexts.fetch('Alice'))
      end
      h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => cell % 10, 'y' => cell / 10})
      h.submit('Bob', context: contexts.fetch('Bob'))
    end
    assert(h.replay('Alice').state[:phase] == :revealing, 'Natural game did not reach final audit')
    h.submit('Alice', context: contexts.fetch('Alice'))
    selection = game.automatic_action(h.replay('Bob'), 'Bob', context: contexts.fetch('Bob'))
    status, plan = game.action_for(selection, h.replay('Bob'), 'Bob', context: contexts.fetch('Bob'))
    assert(status == :ok && plan.events.size == 2, 'Final nonce and fleet were not prepared')
    h.write('Bob', plan.events.first(1))
    partial = h.replay('Bob')
    assert(!partial.finished? && partial.state[:fleets].keys == ['Alice'], 'Nonce-only fixture already finished')
    h.users.each do |user|
      game.cleanup_session_answers(partial, session_id: h.session['__id'], actors: [user], hidden_submissions: vaults.fetch(user))
      assert(stored.call(user), 'An incomplete final audit erased a fleet')
    end
    h.write('Bob', plan.events.drop(1))
    final = h.replay('Alice')
    assert(final.finished? && final.winner == 'Alice' && final.state[:invalid].empty?, 'Honest natural result failed')
    assert(final.state[:fleets].keys.sort == h.users.sort, 'Both fleets were not publicly verified')
    before = h.events('Alice')
    h.users.each { |user| step(h, runners.fetch(user), user, count: 3) }
    h.users.each { |user| assert(stored.call(user).nil?, 'Confirmed terminal fleet remains in cold private storage') }
    assert(h.events('Alice') == before, 'Local cleanup changed the public event log')
    h.assert_converged('Battleship terminal private cleanup')

    # A stale terminal replay must not erase a newer uncertain generation or
    # a different session/account which happens to use the same round name.
    newer = vaults['Bob'].prepare(session_id: h.session['__id'], round_id: 'fleet', user: 'Bob', payload: {'ships' => ships.reverse})
    other = vaults['Bob'].prepare(session_id: h.session['__id'] + 1, round_id: 'fleet', user: 'Bob', payload: {'ships' => ships})
    outsider = vaults['Bob'].prepare(session_id: h.session['__id'], round_id: 'fleet', user: 'Watcher', payload: {'ships' => ships})
    cold_game = game.build_session_game
    cold_replay = cold_game.replay(h.session, before, h.repositories.fetch('Bob'))
    cold_game.cleanup_session_answers(cold_replay, session_id: h.session['__id'], actors: ['Bob'], hidden_submissions: vaults['Bob'])
    assert(stored.call('Bob').commitment == newer.commitment, 'A stale terminal receipt erased a newer uncertain fleet')
    assert(stored.call('Bob', h.session['__id'] + 1).commitment == other.commitment, 'Cleanup crossed a session boundary')
    assert(vaults['Bob'].reveal(session_id: h.session['__id'], round_id: 'fleet', user: 'Watcher').commitment == outsider.commitment,
      'Cleanup crossed an actor boundary')
    assert(cold_replay.winner == final.winner && cold_replay.history.map(&:text) == final.history.map(&:text),
      'Cold public replay changed after private file cleanup')
  ensure
    runners.each_value(&:close)
    h.users.each { |user| h.as(user) { h.view(user)&.leave } }
  end
end

puts 'PASS Battleship confirmed-fleet cleanup: natural native finish, real private files, cold rejoin/replay, partial audit, session/actor/uncertain-generation isolation'
