# frozen_string_literal: true
require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

game = Harness.new.game
players = %w[Alice Bob Carol]
balances = {0 => 10, 1 => 10}
cases = [
  ['rock_paper_scissors', {0 => {choice: 'rock'}, 1 => {choice: 'rock'}}, :draw],
  ['rock_paper_scissors', {0 => {choice: nil}, 1 => {choice: nil}}, :no_winner],
  ['rock_paper_scissors', {0 => {choice: nil}, 1 => {choice: 'rock'}}, :won],
  ['guess_number', {0 => {best: {distance: 1}}, 1 => {best: {distance: 1}}}, :draw],
  ['guess_number', {0 => {best: nil}, 1 => {best: nil}}, :no_winner],
  ['blackjack', {0 => {score: 21}, 1 => {score: 21}}, :draw],
  ['blackjack', {0 => {score: 22}, 1 => {score: 22}}, :no_winner],
  ['risky_dice', {0 => {score: 26}, 1 => {score: 30}}, :no_winner],
  ['copy_number', {0 => {correct: false}, 1 => {correct: false}}, :no_winner],
  ['sound_order', {0 => {correct: false, misplaced: 6}, 1 => {correct: false, misplaced: 2}}, :no_winner],
  ['sound_order', {0 => {correct: true, misplaced: 0}, 1 => {correct: false, misplaced: 3}}, :won],
  ['rhythm', {0 => {score: 0}, 1 => {score: 0}}, :draw],
  ['simon', {0 => {score: 0}, 1 => {score: 0}}, :draw],
  ['quiz', {0 => {correct: false}, 1 => {correct: false}}, :quiz],
  ['quiz', {0 => {correct: true}, 1 => {correct: true}}, :quiz]
]
cases.each do |kind, results, outcome|
  before = Marshal.dump([balances, results])
  result = LOGIC::ChallengeEngine.settlement(kind, balances: balances, results: results)
  assert_equal(outcome, result.outcome, kind)
  text = game.send(:settlement_text, result, players)
  assert(!text.match?(/\n\n|\A\n|\n\z/), kind)
  assert_equal(outcome == :draw, text.include?('The challenge ends in a draw.'), kind)
  assert_equal(outcome == :no_winner, text.include?('No one wins the challenge.'), kind)
  if outcome == :quiz
    assert_equal(result.grants.empty?, text == 'No one answered correctly.')
    assert(!text.include?('wins') && !text.include?('draw'))
  end
  assert_equal(before, Marshal.dump([balances, results]), 'Presentation changed results')
end

# A tied eligible score can coexist with a third player's bust penalty.
result = LOGIC::Settlement.difference(balances: {0 => 10, 1 => 10, 2 => 10},
  scores: {0 => 20, 1 => 20, 2 => 24}, ceiling: 21)
history = []
game.send(:append_notices, history, [[:challenge_details, 'blackjack',
  {0 => {score: 20}, 1 => {score: 20}, 2 => {score: 24}}, nil],
  [:challenge_result, 1, result]], 70, players)
assert_equal(["The challenge ends in a draw.\nCarol loses 3 penalty feathers."], history.map(&:text))
assert_equal({0 => 10, 1 => 10, 2 => 7}, result.balances)

# A missing private trace is excluded; its placeholder zero is not a rival's
# tied, legitimately played zero, and cannot manufacture a draw.
result = LOGIC::ChallengeEngine.settlement('simon', balances: balances,
  results: {0 => {score: 0}, 1 => {score: 0}}, excluded: [1])
assert_equal(:won, result.outcome)
assert_equal(0, result.winner)
assert_equal('Alice wins.', game.send(:settlement_text, result, players))

puts 'PASS challenge draw/no-winner/quiz distinction, one result per line, actual penalties and excluded private attempts'
