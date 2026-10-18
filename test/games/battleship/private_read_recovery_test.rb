require_relative '../../support/session_runner'
require_relative '../../support/hidden_game_read_storage'
require_relative '../../../games/battleship'

Dir.mktmpdir('battleship-private-read-') do |directory|
  game = GameRoomGames::Battleship.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  storage = HiddenGameReadStorage.new(HiddenSubmissionFiles.new(directory))
  vault = HiddenSubmissions::Vault.new(storage)
  contexts = h.users.to_h do |user|
    [user, GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
      hidden_submissions: user == 'Bob' ? vault : HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
  end
  h.submit('Alice', context: contexts.fetch('Alice'))
  ships = [[0, 1, 2, 3], [20, 21, 22], [40, 41, 42], [60, 61], [80, 81], [85, 86], [8], [28], [48], [68]]
  h.users.each do |user|
    h.submit(user, {'kind' => 'command', 'action' => 'seal', 'ships' => JSON.generate(ships)}, context: contexts.fetch(user))
  end
  h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
  assert(h.replay('Bob').state[:phase] == :answering, 'Fixture did not reach the first shot')

  # A cold reader cannot rely on the placement screen's in-memory fleet.
  %i[answering revealing].each do |phase|
    storage.unreadable = true
    runner = runner_for(h, 'Bob')
    runner.instance_variable_get(:@context_template).hidden_submissions = vault
    begin
      before = h.events('Bob').size
      step(h, runner, 'Bob')
      assert(!runner.instance_variable_get(:@internal_error), "#{phase}: a private read error stopped the runner")
      assert(runner.instance_variable_get(:@automatic_retry_key), "#{phase}: missing ordinary retry/backoff")
      assert(h.events('Bob').size == before, "#{phase}: an unreadable fleet produced an event")
      reads = storage.reads
      step(h, runner, 'Bob', count: 20)
      assert(storage.reads == reads, "#{phase}: the unavailable file was reread every tick")
      storage.unreadable = false
      step(h, runner, 'Bob')
      assert(h.events('Bob').size == before, "#{phase}: retry delay was bypassed")
      sleep 1.05
      step(h, runner, 'Bob', count: 3)
      assert(h.events('Bob').size > before, "#{phase}: the valid private fleet did not recover")
      after = h.events('Bob').size
      h.broker.deliver(duplicate: true)
      step(h, runner, 'Bob', count: 4)
      assert(h.events('Bob').size == after, "#{phase}: duplicate feed repeated the private action")
      h.assert_converged("Battleship #{phase} private file recovery")
    ensure
      runner.close
    end

    next unless phase == :answering
    assert(h.replay('Alice').state[:shots]['Alice'][0] == 'hit', 'Recovered answer did not match the sealed fleet')
    assert(h.replay('Alice').state[:fleets].empty?, 'The first recovered answer exposed the fleet')
    misses = (0...100).to_a - ships.flatten
    ships.flatten.drop(1).each do |cell|
      miss = misses.shift
      h.submit('Bob', {'kind' => 'grid', 'action' => 'select', 'x' => miss % 10, 'y' => miss / 10})
      h.submit('Alice', context: contexts.fetch('Alice'))
      h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => cell % 10, 'y' => cell / 10})
      h.submit('Bob', context: contexts.fetch('Bob'))
    end
    assert(h.replay('Alice').state[:phase] == :revealing, 'Fixture did not reach the audited final reveal')
    h.submit('Alice', context: contexts.fetch('Alice'))
  end
  final = h.replay('Alice')
  assert(final.finished? && final.winner == 'Alice', 'Recovered final reveal did not finish the real game')
  assert(final.state[:fleets]['Bob'] == ships, 'The audited final fleet changed during read recovery')
end

puts 'PASS Battleship native private-file recovery: answer, final reveal, bounded retry, audit and exactly-once events'
