require_relative '../../support/session_runner'
require_relative '../../support/hidden_submission_files'
require_relative '../../../games/krowa'
require_relative '../../../lib/saved_games'

class KrowaCleanupFiles < HiddenSubmissionFiles
  def update_json(name, default:)
    value = read_json(name, default: default)
    yield value
    write_json(name, value)
    value
  end
end

Dir.mktmpdir('krowa-confirmed-cleanup-') do |directory|
  bank = GameRoomGames::KrowaWordBank.new(GameRoomKrowa::WordRepository.new(%w[kot las dom rak sok]))
  game = GameRoomGames::Krowa.new(bank: bank)
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob],
    options: game.default_options.merge('variant' => 'race', 'length' => 3, 'race_scoring' => 'time'))
  h.start
  files = KrowaCleanupFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(files.storage)
  runner = runner_for(h, 'Alice')
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  read_secret = ->(round, session_id = h.session['__id'], actor = 'Alice') do
    HiddenSubmissions::Vault.new(HiddenSubmissions::ProgramStorage.new(files)).reveal(
      session_id: session_id, round_id: "krowa:#{round}", user: actor)
  end
  begin
    step(h, runner, 'Alice', count: 2)
    first = read_secret.call(1)
    assert(first && h.replay('Alice').state[:phase] == :active, 'First active secret is unavailable')
    assert(game.saved_private_data(h.replay('Alice'), context: runner.send(:context))['commitment'] == first.commitment,
      'Active word is not available to the ordinary archive')

    h.submit('Alice', {'kind' => 'command', 'action' => 'reroll', 'round' => 1}, context: runner.send(:context))
    selection = game.automatic_action(h.replay('Alice'), 'Alice', context: runner.send(:context))
    status, reveal = game.action_for(selection, h.replay('Alice'), 'Alice', context: runner.send(:context))
    assert(status == :ok && reveal.events.map(&:action) == %w[krowa_nonce krowa_word], 'Reroll reveal fixture failed')
    h.write('Alice', reveal.events.first(1))
    partial = h.replay('Alice')
    game.cleanup_session_answers(partial, session_id: h.session['__id'], actors: ['Alice'], hidden_submissions: vault)
    assert(read_secret.call(1).commitment == first.commitment, 'Nonce-only reveal removed the still-needed secret')
    invalid = h.events('Alice').last.merge('__id' => h.events('Alice').last['__id'] + 1,
      'action' => 'krowa_word', 'value' => (%w[kot las dom rak sok] - [first.payload['word']]).first)
    rejected = game.replay(h.session, h.events('Alice') + [invalid], h.repositories.fetch('Alice'))
    assert(rejected.accepted_events.length == partial.accepted_events.length, 'Wrong public word was accepted')
    game.cleanup_session_answers(rejected, session_id: h.session['__id'], actors: ['Alice'], hidden_submissions: vault)
    assert(read_secret.call(1).commitment == first.commitment, 'Rejected word removed its secret')

    h.write('Alice', reveal.events.drop(1))
    step(h, runner, 'Alice', count: 3)
    second = read_secret.call(2)
    assert(h.replay('Alice').state[:round] == 2 && second, 'Second active word was not prepared')
    assert(read_secret.call(1).nil?, 'Verified previous word remains in cold private storage after reroll')

    # Use the ordinary archive codec and native close/new-table/import path.
    # A public receipt for round 1 must not consume the restored active round 2.
    original_session_id = h.session['__id']
    boundary = h.as('Alice') { h.transports.fetch('Alice').freeze_game(h.session) }
    snapshot = h.repositories.fetch('Alice').snapshot_for(h.session, force_events: true)
    saves = SavedGames.new(files, owner: 'Alice')
    saved = saves.put(game: game, table: h.table, snapshot: snapshot, repository: h.repositories.fetch('Alice'),
      now: boundary.created_at)
    assert(SavedGames.new(KrowaCleanupFiles.new(directory), owner: 'Alice').fetch(saved['id']) == saved,
      'Archive did not survive a cold file read')
    assert(saved['private_data']['commitment'] == second.commitment, 'Archive lost the active word')
    runner.close
    h.as('Bob') { h.view('Bob').leave }
    h.as('Alice') { h.transports.fetch('Alice').deactivate_table(table_id: h.table['__id']) }
    fresh = h.as('Alice') do
      h.transports.fetch('Alice').create_room(name: 'Resumed cleanup race', game: game.id, owner: 'Alice',
        game_options: saved['options'], resume_save_id: saved['id'])
    end
    h.instance_variable_set(:@table, fresh)
    assert(h.join('Bob'), 'Guest could not join the restored room')
    restore = saves.restored_data(saved, game: game, table_id: fresh['__id'], now: saved['saved_at'] + 60)
    restored = h.as('Alice') do
      h.repositories.fetch('Alice').restore_session(table: fresh, game: game.id,
        players: restore[:players], options: saved['options'], restore: restore)
    end
    h.instance_variable_set(:@session, restored)
    assert(h.session['__id'] != original_session_id, 'Restore reused the old session identity')
    runner = runner_for(h, 'Alice')
    runner.instance_variable_get(:@context_template).hidden_submissions =
      HiddenSubmissions::Vault.new(HiddenSubmissions::ProgramStorage.new(files))
    step(h, runner, 'Alice', count: 3)
    assert(read_secret.call(2).commitment == second.commitment && h.replay('Alice').state[:phase] == :active,
      'Old receipt erased or changed the restored active secret')

    h.submit('Bob', {'kind' => 'question', 'action' => 'submit', 'question_id' => 'krowa-answer-2',
      'answer' => second.payload.fetch('word')}, context: runner.send(:context))
    step(h, runner, 'Alice', count: 5)
    final = h.replay('Alice')
    assert(final.finished? && final.winner == 'Bob', 'Natural resumed race did not finish normally')
    assert(final.accepted_events.count { |event| event['action'] == 'krowa_word' } == 2,
      'Both public word audits were not accepted')
    assert(read_secret.call(2).nil?, 'Natural final reveal remains in cold private storage')
    before = h.events('Alice')
    h.assert_converged('Krowa resumed terminal cleanup')
    runner.close
    runner = runner_for(h, 'Alice')
    runner.instance_variable_get(:@context_template).hidden_submissions =
      HiddenSubmissions::Vault.new(HiddenSubmissions::ProgramStorage.new(files))
    step(h, runner, 'Alice', count: 3)
    assert(h.events('Alice') == before && h.replay('Alice').history.map(&:text) == final.history.map(&:text),
      'Cold terminal worker altered public history')

    newer = vault.prepare(session_id: h.session['__id'], round_id: 'krowa:2', user: 'Alice',
      payload: {'word' => second.payload['word'], 'day' => nil})
    outsider = vault.prepare(session_id: h.session['__id'], round_id: 'krowa:2', user: 'Watcher', payload: {'word' => 'kot', 'day' => nil})
    cold_game = game.build_session_game
    cold_final = cold_game.replay(h.session, before, h.repositories.fetch('Alice'))
    cold_game.cleanup_session_answers(cold_final, session_id: h.session['__id'], actors: ['Alice'], hidden_submissions: vault)
    assert(read_secret.call(2).commitment == newer.commitment, 'Old receipt erased a newer uncertain generation')
    assert(read_secret.call(2, original_session_id).commitment == second.commitment, 'Cleanup crossed the original session boundary')
    assert(read_secret.call(2, h.session['__id'], 'Watcher').commitment == outsider.commitment, 'Cleanup crossed the actor boundary')
  ensure
    runner.close
    h.users.each { |user| h.as(user) { h.view(user)&.leave } }
  end
end

puts 'PASS Krowa confirmed-word cleanup: reroll, nonce-only/rejected protection, native save/restore, natural result, cold replay and session/actor/uncertain isolation'
