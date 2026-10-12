# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

game = Harness.new.game
players = %w[Alice Bob Carol]

# Every description states who is affected, not an ambiguous imperative
# such as "move back" when the actual recipient is an opponent or a trap.
LOGIC::Cards::TYPES.each do |card|
  text = game.card_description(card.id)
  assert(text.start_with?(game.card_name(card.id) + '. '))
  assert(text.end_with?('.'))
  if card.cost.positive?
    assert(text.end_with?("Cost: #{card.cost} #{card.cost == 1 ? 'feather' : 'feathers'}."), card.id)
  else
    assert(!text.include?('Cost:'), "#{card.id} describes a nonexistent cost")
  end
  assert(text.include?("Receive #{card.gain} feathers"), "#{card.id}: missing immediate reward") if card.gain.positive?
  case card.target
  when :square
    assert(text.include?('on your square.'), "#{card.id}: missing placement")
    assert(text.include?('duck'), "#{card.id}: missing trap recipient")
  when :opponent
    assert(text.include?('opponent'), "#{card.id}: misleading recipient")
  when :any
    assert(text.include?('yourself or another duck'), "#{card.id}: missing target choice")
  end
  card.effects.each do |effect, amount, extra|
    fragment = case effect
    when :move then "#{amount.negative? ? 'back' : 'forward'} #{amount.abs} square"
    when :random_move
      assert(text.include?('random direction'), "#{card.id}: missing direction")
      card.id == 'ejectable_seat' ? '1 or 2 squares' : "between #{amount} and #{extra} squares"
    when :steal_feathers then "Take #{amount} feathers"
    when :skip
      card.id == 'sandwich' ? 'skip this turn' : /skip(?:s)? #{amount} turns/
    when :die
      sides = {3 => 'three', 6 => 'six', 10 => 'ten', 12 => 'twelve'}.fetch(amount)
      assert(text.include?("next #{extra}") && text.include?('race rolls'), card.id) if extra.positive?
      "#{sides}-sided die"
    when :quiz then 'Each correct answer earns 4 feathers'
    when :cards then "Draw #{amount} cards"
    when :steal_cards then 'Take a random card from an opponent'
    when :everyone_cards then 'everyone draws a card'
    when :swap_hands then 'Exchange all your cards'
    when :pass_hands then 'Everyone passes all their cards'
    when :group_challenge then 'all unfrozen ducks'
    when :duel then 'two-player challenge'
    when :feathers then "receives #{amount} feathers"
    else raise "Missing description assertion: #{effect}"
    end
    assert(fragment.is_a?(Regexp) ? text.match?(fragment) : text.include?(fragment),
      "#{card.id}: missing effect #{fragment.inspect}")
  end
end

state_at = lambda do |positions|
  state = LOGIC::Race.start(player_count: positions.length, laps: 3, seed: 77,
    enabled_challenges: ['dice_duel'])
  state[:occupants] = {}
  positions.each_with_index do |progress, seat|
    state[:racers][seat][:progress] = progress
    LOGIC::Board.arrive!(state[:occupants], seat, LOGIC::Board.square(progress))
  end
  state
end
play = lambda do |state, type, seat: 0, target: nil|
  card = LOGIC::Cards::Copy.new("test-#{seat}-#{type}", type)
  state[:racers][seat][:hand] << card
  state[:turn] = seat
  assert(LOGIC::Race.new(state).apply(seat: seat, revision: state[:revision],
    action: {kind: :play, card: card.id, target: target}))
end
roll_one = lambda do |state, seat|
  state[:turn] = seat
  seed = (0..100).find { |value| Random.new(value).rand(6).zero? }
  state[:random] = Random.new(seed)
  assert(LOGIC::Race.new(state).apply(seat: seat, revision: state[:revision], action: {kind: :roll}))
end
render = lambda do |state|
  before = DuckGameAdapterTest.semantic(state)
  history = []
  game.send(:append_notices, history, state[:notices], 77, players)
  assert_equal(before, DuckGameAdapterTest.semantic(state), 'Speech altered the race or its next random value')
  assert(history.all? { |entry| entry.event_id == 77 && !entry.text.match?(/\n\n|\A\n|\n\z/) })
  history
end

# Actual accepted effects disclose their distance on a separate line and
# always retain the numbered destination. Near the start, report the actual
# one-square move, not the card's nominal two.
[[33, -2, 31], [1, -1, 0]].each do |from, distance, destination|
  state = state_at.call([from, 40, 70])
  play.call(state, 'tiny_recoil')
  moved = state[:notices].find { |notice| notice.first == :moved }
  assert_equal(distance, moved[3])
  assert_equal(destination, state[:racers][0][:progress])
  entries = render.call(state)
  text = entries.find { |entry| entry.kind == :moved }.text
  count = distance.abs
  assert_equal("Alice moves back #{count} #{count == 1 ? 'square' : 'squares'}.",
    entries.find { |entry| entry.kind == :displacement }.text)
  assert(text.include?("Alice lands on square #{LOGIC::Board.square(destination)}."))
end

state = state_at.call([8, 32, 70])
play.call(state, 'guided_missile', target: 1)
entries = render.call(state)
assert_equal('Bob moves back 10 squares.', entries.find { |entry| entry.kind == :displacement }.text)
assert(entries.find { |entry| entry.kind == :moved }.text.start_with?('Bob lands on square 23.'))
assert_equal(22, state[:racers][1][:progress])

# Landing on a previously placed card uses the same effect path and reports
# both the die destination and the destination after the trap.
state = state_at.call([20, 19, 27])
play.call(state, 'mine')
roll_one.call(state, 1)
history = render.call(state).reject { |entry| entry.kind == :scenery }
assert_equal([:rolled, :moved, :skip_added, :trap, :displacement, :moved, :feathers], history.map(&:kind))
assert_equal('Bob lands on square 21. Water lilies.', history[1].text)
assert_equal('Bob moves back 15 squares.', history[4].text)
assert_equal('Bob lands on square 6. South bank.', history[5].text)

# The duck arriving last initiates the encounter; the first entry in the
# participant array is its opponent, not the initiator.
state = state_at.call([2, 1, 2])
roll_one.call(state, 1)
assert_equal([2, 1], state[:challenge][:participants])
text = render.call(state).find { |entry| entry.kind == :challenge }.text
assert_equal("Bob starts a challenge with Carol.\nDice duel.", text)

%w[challenge super_challenge curiosity].each do |card|
  state = state_at.call([2, 8, 16])
  play.call(state, card, seat: 1, target: card == 'challenge' ? 0 : nil)
  text = render.call(state).find { |entry| [:challenge, :quiz_question].include?(entry.kind) }.text
  others = card == 'challenge' ? 'Alice' : 'Alice, Carol'
  expected = card == 'curiosity' ? 'Question for everyone.' : "Bob starts a challenge with #{others}.\nDice duel."
  assert_equal(expected, text)
end
state = state_at.call([2, 5, 16])
roll_one.call(state, 1)
assert_equal(:square_question, state[:challenge][:trigger])
assert_equal('Question for everyone.', render.call(state).find { |entry| entry.kind == :quiz_question }.text)

puts 'PASS all 37 card descriptions, exact effect distances/recipients, actual trap, last-arrival encounter, duel/group/question cards and question square'
