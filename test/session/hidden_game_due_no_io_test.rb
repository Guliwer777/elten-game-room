require_relative '../support/session_runner'
require_relative '../../games/battleship'
require_relative '../../games/scientific_war'

class HiddenDueReadCounter < HiddenSubmissions::MemoryStorage
  attr_reader :reads
  def initialize; super; @reads = 0; end
  def read; @reads += 1; super; end
end

[GameRoomGames::Battleship.new, GameRoomGames::ScientificWar.new].each do |game|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  storage = HiddenDueReadCounter.new
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    hidden_submissions: HiddenSubmissions::Vault.new(storage))
  if game.id == 'battleship'
    h.submit('Alice', context: context)
    ships = [[0, 1, 2, 3], [20, 21, 22], [40, 41, 42], [60, 61], [80, 81], [85, 86], [8], [28], [48], [68]]
    h.users.each { |user| h.submit(user, {'action' => 'seal', 'ships' => JSON.generate(ships)}, context: context) }
    h.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
  else
    h.users.each do |user|
      action = game.legal_actions(h.replay(user), user).find { |item| item['action'] == 'select' }
      h.submit(user, action, context: context)
    end
  end
  fresh = game.build_session_game
  replay = h.replay('Bob')
  before = storage.reads
  20.times { fresh.automatic_action_due?(replay, 'Bob', context: context) }
  assert(storage.reads == before, "#{game.id}: the UI/deadline predicate reads private files")
end

puts 'PASS hidden-game automatic due predicates perform no private storage I/O'
