require_relative '../../support/new_games_fixture'

game = GameRoomGames::Uno.new
players = %w[Alice Bob Carol]
repository = NewGames116Repository.new(players)
options = game.normalize_options('deck' => 'no_mercy')
initial = game.send(:initial_state, players, options)
initial.update(phase: :round_complete, round: 1, dealer_index: 0,
  round_eliminated: {'Alice' => true, 'Bob' => false, 'Carol' => false},
  eliminated: {'Alice' => false, 'Bob' => true, 'Carol' => false})

# A rejected deal cannot bring a No Mercy player back into the completed
# round, nor accept Ruby's negative array index as a seat number.
failures = []
[1, 3, -1, -3].each do |dealer|
  state = Marshal.load(Marshal.dump(initial))
  before = Marshal.dump(state)
  history = []
  event = {'id' => 7, 'actor' => 'Alice', 'action' => 'deal',
    'value' => "2|#{dealer}|#{'1' * 32}|0"}
  accepted = game.send(:apply_deal, state, event, 'Alice', repository, history)
  failures << "UNO accepted an ineligible dealer: #{dealer}" if accepted
  failures << "Rejected deal changed No Mercy state: #{dealer}" unless
    Marshal.dump(state) == before && history.empty?
end
assert(failures.empty?, failures.join("\n"))

# The next eligible dealer still deals to temporary eliminations, while
# permanent score eliminations remain out of play.
state = Marshal.load(Marshal.dump(initial))
history = []
valid = {'id' => 8, 'actor' => 'Alice', 'action' => 'deal',
  'value' => "2|2|#{'2' * 32}|0"}
assert(game.send(:apply_deal, state, valid, 'Alice', repository, history),
  'UNO rejected the next legal deal')
assert(state[:hands]['Alice'].size == 7 && state[:hands]['Carol'].size == 7 &&
  state[:hands]['Bob'].empty?, 'UNO changed who returns for the next round')
assert(state[:round_eliminated].values.none? && state[:eliminated]['Bob'],
  'UNO did not distinguish round and permanent elimination')
assert(history.size == 1 && state[:dealer_index] == 2 && state[:round] == 2,
  'UNO did not record exactly one legal deal')
puts 'PASS UNO: rejected dealers leave completed-round state untouched; legal deal returns No Mercy players'
