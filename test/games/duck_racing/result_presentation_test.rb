require_relative '../../support/duck_game_adapter'
require_relative '../../support/localization'

include GameRoomTest::Assertions

def assert_result_lines(text, expected)
  assert_equal(expected.join("\n"), text, 'Each result must have its own line')
  assert_equal(expected, text.split("\n", -1), 'Result output gained a blank or trailing line')
  assert(!text.include?("\r"), 'Canonical history must use LF; native controls convert it to CRLF')
end

logic = GameRoomDuckRacing
h = DuckGameAdapterTest::Harness.new(kind: 'quiz')
challenge = h.open_round
h.begin_round
engine = logic::ChallengeEngine.start(challenge, resources: h.resources)
question = engine[:model][:question]
correct = question[:choices].fetch(question[:correct_index])
id = challenge[:id]
h.players.each_with_index do |actor, seat|
  trace = logic::ChallengeTrace.new(challenge, seat: seat, resources: h.resources)
  value = seat.zero? ? question[:correct_index] : (question[:correct_index] + 1) % 4
  assert(trace.submit({kind: :answer, value: value, press_id: 1}, at: 100 + seat * 100))
  h.accept({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace.snapshot}, actor: actor)
end
assert_equal(nil, h.replay.state[:last_resolution])
assert(h.replay.history.none? { |entry| entry.kind == :challenge_details })
h.accept({'action' => 'advance', 'challenge' => id}, author: h.owner)
h.players.each_with_index do |actor, seat|
  private_state = h.replay.state[:round][:private]
  prepared = logic::PrivateRound.recover(private_state, seat: seat, user: actor, vault: h.vault(actor))
  prepared.reveal_pages.each do |page|
    h.accept({'action' => 'reveal', 'challenge' => id, 'page' => page}, actor: actor)
  end
  assert_equal(nil, h.replay.state[:last_resolution]) if seat.zero?
end
resolution = h.replay.state[:last_resolution]
assert_equal(correct, resolution[:answer])
details = h.replay.history.select { |entry| entry.kind == :challenge_details }
assert_equal(1, details.length)
assert_result_lines(details.first.text, ["Correct answer: #{correct}."])
assert_result_lines(h.replay.history.find { |entry| entry.kind == :challenge_result }.text,
  ['Alice receives 4 feathers.'])
assert_equal(4, resolution[:settlement].grants.fetch(0))
assert(!resolution[:settlement].grants.key?(1))

numbers = DuckGameAdapterTest::Harness.new(kind: 'copy_number')
number_challenge = numbers.open_round
numbers.begin_round
numbers.accept({'action' => 'submit_trace', 'challenge' => number_challenge[:id],
  'trace' => numbers.private_traces.fetch(0)}, actor: 'Alice')
number_resolution = numbers.replay.state[:last_resolution]
assert_equal(number_resolution[:answer], number_resolution[:results].fetch(0)[:answer],
  'Shorter speech must not discard the verified answer')
assert(numbers.replay.history.none? { |entry| entry.kind == :challenge_details },
  'Copying a visible number must not repeat it and list every answer at the end')
assert_result_lines(numbers.replay.history.find { |entry| entry.kind == :challenge_result }.text,
  ['Alice wins.', 'Alice takes 4 feathers from Bob.'])
assert_equal(4, number_resolution[:settlement].transfers.first.amount)

rps = DuckGameAdapterTest::Harness.new(kind: 'rock_paper_scissors')
rps.open_round
rps.begin_round
rps.finish_private
assert_result_lines(rps.replay.history.find { |entry| entry.kind == :challenge_details }.text,
  ['Alice: Rock.', 'Bob: Scissors.'])

game = numbers.game
accuracy = game.send(:challenge_details_text, 'rhythm', {0 => {score: Rational(250, 3)}}, nil, ['Alice'])
assert_result_lines(accuracy, ['Alice: 83.3% accuracy.'])

# Cover every result format, not only a substring that would also accept all
# players crammed into one line. These are presentation inputs, not fabricated
# actions/results appended to a session.
players = ['ciocia Henia', 'papierek', 'Łucja']
summaries = {
  'rock_paper_scissors' => [{0 => {choice: 'rock'}, 1 => {choice: 'rock'}, 2 => {choice: nil}},
    ['Rock', 'Rock', 'No answer']],
  'guess_number' => [{0 => {best: {value: 42}, attempts: 3}, 1 => {best: {value: 41}, attempts: 1}, 2 => {best: nil}},
    ['42', '41', 'No answer']],
  'simon' => [{0 => {score: 1}, 1 => {score: 6}, 2 => {score: 0}}, ['1 sound', '6 sounds', '0 sounds']],
  'sound_memory' => [{0 => {score: 1}, 1 => {score: 2}, 2 => {score: 0}}, ['1 pair', '2 pairs', '0 pairs']]
}
%w[rhythm hit_duck].each do |kind|
  summaries[kind] = [{0 => {score: Rational(250, 3)}, 1 => {score: 90}, 2 => {score: 0}},
    ['83.3% accuracy', '90.0% accuracy', '0.0% accuracy']]
end
summaries['numbered_balls'] = [{0 => {score: 6}, 1 => {score: 4}, 2 => {score: 3}}, ['6', '4', '3']]
summaries.each do |kind, (results, expected)|
  summary = game.send(:challenge_details_text, kind, results, nil, players)
  assert_result_lines(summary, expected.each_with_index.map { |detail, seat| "#{players[seat]}: #{detail}." })
end
%w[dice_duel blackjack risky_dice sound_order audio_ball axel_pong].each do |kind|
  assert_equal('', game.send(:challenge_details_text, kind, {0 => {point: true}}, nil, players),
    'A score already announced during play must not add a detailed result paragraph')
end
assert_equal('', game.send(:challenge_details_text, 'copy_number',
  {0 => {answer: nil, correct: false}, 1 => {answer: 123, correct: false}}, 456, players),
  'Unsuccessful copying must not add another detailed result paragraph')

# The solution is useful; a second listing of every submitted answer is not.
# Zero is a valid answer, and shortening presentation must not change results.
%w[arithmetic race_question count_ducks quiz].each do |kind|
  [0, 42, 'Żółw'.b].each do |answer|
    results = {0 => {answer: answer, correct: true}, 1 => {answer: 1, correct: false},
      2 => {answer: nil, correct: false}}
    before = Marshal.dump(results)
    summary = game.send(:challenge_details_text, kind, results, answer, players)
    expected_answer = answer.to_s.dup.force_encoding(Encoding::UTF_8)
    assert_result_lines(summary, ["Correct answer: #{expected_answer}."])
    assert_equal(before, Marshal.dump(results), 'Shortening a result changed its data')
  end
end
guess_results = {0 => {best: {value: 41}, attempts: 10}, 1 => {best: {value: 39}, attempts: 1}}
assert_result_lines(game.send(:challenge_details_text, 'guess_number', guess_results, 42, %w[Alice Bob]),
  ['Correct answer: 42.', 'Alice: 41.', 'Bob: 39.'])
settlement = logic::Settlement.difference(balances: {0 => 2, 1 => 5}, scores: {0 => 10, 1 => 4})
summary = game.send(:settlement_text, settlement, %w[Alice Bob])
assert_result_lines(summary, ['Alice wins.', 'Alice takes 5 feathers from Bob.'])
assert_equal(5, settlement.transfers.first.amount, 'Speech must retain the actual transfer, capped by the loser balance')

multiple = logic::Settlement.difference(balances: {0 => 20, 1 => 20, 2 => 20}, scores: {0 => 6, 1 => 2, 2 => 4})
assert_result_lines(game.send(:settlement_text, multiple, %w[Alice Bob Carol]),
  ['Alice wins.', 'Alice takes 4 feathers from Bob.', 'Alice takes 2 feathers from Carol.'])
penalties = logic::Settlement.difference(balances: {0 => 20, 1 => 20, 2 => 20},
  scores: {0 => 20, 1 => 22, 2 => 23}, ceiling: 21)
assert_result_lines(game.send(:settlement_text, penalties, %w[Alice Bob Carol]),
  ['Alice wins.', 'Alice takes 2 feathers from Bob.', 'Alice takes 3 feathers from Carol.',
    'Bob loses 1 penalty feather.', 'Carol loses 2 penalty feathers.'])
grants = logic::Settlement.quiz(balances: {0 => 18, 1 => 18}, answers: {0 => true, 1 => true})
assert_result_lines(game.send(:settlement_text, grants, %w[Alice Bob]),
  ['Alice receives 4 feathers.', 'Bob receives 4 feathers.'])
tie = logic::Settlement.difference(balances: {0 => 18, 1 => 18}, scores: {0 => 4, 1 => 4})
assert_result_lines(game.send(:settlement_text, tie, %w[Alice Bob]), ['The challenge ends in a draw.'])

localized = {
  'en' => ['Correct answer: 42.', 'No answer'],
  'pl' => ['Poprawna odpowiedź: 42.', 'Brak odpowiedzi'],
  'cs' => ['Správná odpověď: 42.', 'Bez odpovědi'],
  'es' => ['Respuesta correcta: 42.', 'Sin respuesta'],
  'ru' => ['Правильный ответ: 42.', 'Нет ответа']
}
begin
  localized.each do |code, (solution, missing)|
    GameRoomTestLocalization.use_language(code)
    %w[arithmetic race_question count_ducks quiz].each do |kind|
      assert_result_lines(game.send(:challenge_details_text, kind,
        {0 => {answer: 42, correct: true}, 1 => {answer: nil, correct: false}}, 42, %w[Alice Bob]),
        [solution])
    end
    assert_result_lines(game.send(:challenge_details_text, 'guess_number',
      {0 => {best: {value: 41}, attempts: 10}, 1 => {best: nil, attempts: 0}}, 42, %w[Alice Bob]),
      [solution, 'Alice: 41.', "Bob: #{missing}."])
    %w[copy_number dice_duel blackjack risky_dice].each do |kind|
      assert_equal('', game.send(:challenge_details_text, kind, {0 => {score: 21}}, nil, ['Alice']),
        "#{code}: a completed score reappeared in the translated result")
    end
  end
ensure
  GameRoomTestLocalization.use_language('en')
end
puts "PASS Duck Racing concise solutions, completed scores, closest answers in five languages and #{summaries.length} retained detailed formats"
