require_relative '../../support/session_runner'
require_relative '../../support/hidden_game_read_storage'
require_relative '../../../games/scientific_war'

Dir.mktmpdir('scientific-war-private-read-') do |directory|
  game = GameRoomGames::ScientificWar.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  storage = HiddenGameReadStorage.new(HiddenSubmissionFiles.new(directory))
  vault = HiddenSubmissions::Vault.new(storage)
  contexts = h.users.to_h do |user|
    [user, GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
      hidden_submissions: user == 'Bob' ? vault : HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
  end
  choices = {}
  h.users.each do |user|
    action = game.legal_actions(h.replay(user), user).find { |item| item['action'] == 'select' }
    choices[user] = action.fetch('card')
    h.submit(user, action, context: contexts.fetch(user))
  end
  assert(h.replay('Bob').state[:phase] == :revealing, 'Fixture did not reach the sealed choice reveal')
  original = vault.reveal(session_id: h.session['__id'], round_id: 'trick:1', user: 'Bob')
  alternative = h.replay('Bob').state[:hands]['Bob'].find { |card| card != original.payload.fetch('card') }
  vault.prepare(session_id: h.session['__id'], round_id: 'trick:1', user: 'Bob', payload: {'card' => alternative})
  storage.unreadable = true
  runner = runner_for(h, 'Bob')
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  begin
    before = h.events('Bob').size
    step(h, runner, 'Bob')
    assert(!runner.instance_variable_get(:@internal_error), 'An unreadable choice stopped the runner')
    assert(h.events('Bob').size == before, 'An unreadable choice produced a reveal')
    assert(runner.instance_variable_get(:@automatic_retry_key), 'The unreadable choice bypassed the ordinary retry/backoff')
    reads = storage.reads
    step(h, runner, 'Bob', count: 20)
    assert(storage.reads == reads, 'The unreadable private choice was polled every tick')
    storage.unreadable = false
    step(h, runner, 'Bob')
    assert(h.events('Bob').size == before, 'Recovery bypassed the ordinary retry delay')
    sleep 1.05
    step(h, runner, 'Bob', count: 3)
    assert(h.replay('Bob').state[:reveals]['Bob'] == original.payload.fetch('card'), 'Recovery revealed a newer uncommitted choice')
    after = h.events('Bob').size
    h.broker.deliver(duplicate: true)
    step(h, runner, 'Bob', count: 4)
    assert(h.events('Bob').size == after, 'Duplicate feed repeated the choice reveal')
    h.submit('Alice', context: contexts.fetch('Alice'))
    assert(h.replay('Alice').state[:trick] == 2, 'Recovered sealed choices did not finish the trick')
    h.assert_converged('Scientific War private read recovery')
  ensure
    runner.close
  end
end

puts 'PASS Scientific War native private-file recovery: bounded retry, accepted commitment version, no duplicates and next trick'
