require_relative '../../support/session_runner'
require_relative '../../../games/battleship'

game = GameRoomGames::Battleship.new
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
h.start
ships = [[0, 1, 2, 3], [20, 21, 22], [40, 41, 42], [60, 61], [80, 81], [85, 86], [8], [28], [48], [68]]
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'], hidden_submissions: vault)
h.submit('Alice', context: context)
h.users.each do |user|
  h.submit(user, {'action' => 'seal', 'ships' => JSON.generate(ships)}, context: context)
end
h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
original = storage.read
changed = Marshal.load(Marshal.dump(ships))
changed[0] = [1, 2, 3, 4]
assert(game.send(:legal_fleet?, h.replay('Bob').state, changed), 'Corruption fixture must remain a legal fleet')
storage.update do |root|
  root.fetch('entries').each_value do |entry|
    entry['payload']['ships'] = changed if entry['user'] == 'Bob'
  end
end
before = h.events('Bob').size
fresh = game.build_session_game
fresh.prepare_view(h.replay('Bob'), 'Bob', context: context)
surface = fresh.surface_spec(h.replay('Bob'), 'Bob')
assert(surface.parts.last.surface.cells.flatten.none? { |cell| cell.include?('ship') },
  'A changed private payload was displayed as the accepted fleet')
status, plan = fresh.action_for({'action' => 'answer'}, h.replay('Bob'), 'Bob', context: context)
assert(status != :ok && plan.nil?, 'A changed private payload produced a false public shot result')
assert(h.events('Bob').size == before, 'Rejected private corruption changed the public history')
storage.update { |root| root.replace(original) }
status, plan = fresh.action_for({'action' => 'answer'}, h.replay('Bob'), 'Bob', context: context)
assert(status == :ok && plan.events.first.value == 'hit', 'The original accepted fleet did not recover')
h.write('Bob', plan.events)
h.assert_converged('recovered original private fleet')

puts 'PASS Battleship local private integrity: wrong payload is neither displayed nor used to publish a shot result'
