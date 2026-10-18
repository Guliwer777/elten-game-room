require_relative '../../support/session_runner'
require_relative '../../support/hidden_game_read_storage'
require_relative '../../../games/krowa'

Dir.mktmpdir('krowa-private-read-') do |directory|
  bank = GameRoomGames::KrowaWordBank.new(GameRoomKrowa::WordRepository.new(%w[kot las dom rak sok]))
  game = GameRoomGames::Krowa.new(bank: bank)
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob],
    options: game.default_options.merge('variant' => 'race', 'length' => 3, 'race_scoring' => 'time'))
  h.start
  storage = HiddenGameReadStorage.new(HiddenSubmissionFiles.new(directory))
  vault = HiddenSubmissions::Vault.new(storage)
  runner = runner_for(h, 'Alice')
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  begin
    %i[setup active revealing].each do |phase|
      assert(h.replay('Alice').state[:phase] == phase, "Fixture did not reach #{phase}")
      storage.unreadable = true
      before = h.events('Alice').size
      step(h, runner, 'Alice')
      assert(runner.instance_variable_get(:@automatic_retry_key), "#{phase}: private read failed without retry")
      assert(!runner.instance_variable_get(:@internal_error), "#{phase}: private read stopped the runner")
      reads = storage.reads
      step(h, runner, 'Alice', count: 20)
      assert(storage.reads == reads && h.events('Alice').size == before, "#{phase}: retries were not bounded")
      storage.unreadable = false
      sleep 1.05
      step(h, runner, 'Alice')
      assert(h.events('Alice').size > before, "#{phase}: valid private word did not recover")
      h.assert_converged("Krowa #{phase} recovery")
      if phase == :setup
        replay = h.replay('Alice')
        secret = vault.reveal(session_id: h.session['__id'], round_id: 'krowa:1', user: 'Alice')
        assert(!JSON.generate(h.events('Bob')).include?(secret.payload.fetch('word')), 'Prepared secret leaked before guesses')
        h.submit('Bob', {'kind' => 'question', 'action' => 'submit', 'question_id' => 'krowa-answer-1',
          'answer' => secret.payload.fetch('word')}, context: runner.send(:context))
      end
    end
    final = h.replay('Bob')
    assert(final.finished? && final.winner == 'Bob', 'Recovered Krowa race did not finish normally')
    assert(final.state[:attempts].size == 1, 'Private read retry counted an extra guess')
    before = h.events('Bob').size
    h.broker.deliver(duplicate: true)
    step(h, runner, 'Alice', count: 5)
    assert(h.events('Bob').size == before, 'Duplicate delivery produced another reveal')
  ensure
    runner.close
  end
end

puts 'PASS Krowa private read recovery: prepare, score, reveal, bounded retry and unchanged attempt count'
