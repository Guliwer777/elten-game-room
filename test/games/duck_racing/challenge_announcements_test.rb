# frozen_string_literal: true

require_relative '../../support/duck_challenge_ui'
require_relative '../../../games/duck_racing_support/challenge_presentation'
include DuckChallengeTest

presenter = GameRoomDuckRacing::ChallengePresentation
project = ->(kind, view, previous = nil, viewer = 0) {
  original, old = Marshal.dump(view), Marshal.dump(previous)
  result = presenter.project(kind: kind, view: view, viewer: viewer, previous_view: previous)
  assert_equal(original, Marshal.dump(view), 'Presentation mutated its current view')
  assert_equal(old, Marshal.dump(previous), 'Presentation mutated its previous view')
  result
}

# The field keeps the complete hand. Accepted public history, not this local
# projection, announces each draw or roll once to all players.
blackjack = ENGINE.view(challenge_state('blackjack'), seat: 0)
blackjack[:own].merge!(card_ranks: [2, 4], total: 6, done: false)
blackjack[:finished] = false
assert_equal('Press Space to draw a card or Enter to keep your cards. Waiting for your turn.', project.call('blackjack', blackjack)[:announcement])
drawn = Marshal.load(Marshal.dump(blackjack))
drawn[:own].merge!(card_ranks: [2, 4, 12], total: 16)
result = project.call('blackjack', drawn, blackjack)
assert_equal('', result[:announcement])
assert_equal('Waiting for your turn. Cards: 2, 4, Queen. Total: 16.', result[:status])
assert(result[:header].include?(result[:status]))
assert_equal('', project.call('blackjack', drawn, drawn)[:announcement])
stood = Marshal.load(Marshal.dump(drawn))
stood[:own][:done] = true
result = project.call('blackjack', stood, drawn)
assert_equal('', result[:announcement])
assert(result[:status].include?('Cards: 2, 4, Queen. Total: 16.'))
assert_equal(false, result[:enabled])
finished = Marshal.load(Marshal.dump(stood))
finished[:finished] = true
result = project.call('blackjack', finished, stood)
assert_equal('', result[:announcement])
assert(result[:header].include?('Cards: 2, 4, Queen. Total: 16.'))
spectator = blackjack.reject { |key, _value| key == :own }
assert_equal('You are watching.', project.call('blackjack', spectator, nil, nil)[:status])

# The full roll stays inspectable but is not spoken again by local refresh.
%w[dice_duel risky_dice].each do |kind|
  waiting = ENGINE.view(challenge_state(kind), seat: 0)
  waiting[:finished] = false
  waiting[:own].merge!(rolls: [], total: 0, done: false)
  rolled = Marshal.load(Marshal.dump(waiting))
  rolled[:own].merge!(rolls: [[2, 3]], total: 5, done: kind == 'dice_duel')
  result = project.call(kind, rolled, waiting)
  assert_equal('', result[:announcement])
  assert_equal('', project.call(kind, rolled, rolled)[:announcement])
  assert(result[:header].include?('Roll: 2, 3. Total: 5.'))
  next if kind == 'dice_duel'

  saved = Marshal.load(Marshal.dump(rolled))
  saved[:own][:done] = true
  result = project.call(kind, saved, rolled)
  assert_equal('', result[:announcement])
  assert(result[:header].include?('Roll: 2, 3. Total: 5.'))
  assert_equal('', project.call(kind, saved, saved)[:announcement])
end

# All matched positions remain inspectable during either player's turn and
# after completion; live choices/results come from the sound-event queue.
memory = ENGINE.view(challenge_state('sound_memory'), seat: 0)
memory[:public].merge!(turn: 0, removed: [2, 7])
matched = Marshal.load(Marshal.dump(memory))
matched[:public].merge!(turn: 1, removed: [2, 7, 3, 8])
result = project.call('sound_memory', matched, memory)
assert_equal('', result[:announcement])
assert(result[:status].include?('Matched positions: 2, 7, 3, 8.'))
assert(result[:status].start_with?('Waiting for your turn.'))
assert_equal('', project.call('sound_memory', matched, matched)[:announcement])
coalesced = Marshal.load(Marshal.dump(matched))
coalesced[:public][:removed] += [1, 0, 4, 9]
assert_equal('', project.call('sound_memory', coalesced, matched)[:announcement])
last_pair = Marshal.load(Marshal.dump(coalesced))
last_pair[:public][:removed] += [5, 6]
last_pair[:finished] = true
result = project.call('sound_memory', last_pair, coalesced)
assert_equal('', result[:announcement])
assert(result[:status].include?('Matched positions: 2, 7, 3, 8, 1, 0, 4, 9, 5, 6.'))

simon = ENGINE.view(challenge_state('simon'), seat: 0)
simon[:own].merge!(phase: :listening, level: 6)
response = Marshal.load(Marshal.dump(simon))
response[:own][:phase] = :responding
result = project.call('simon', response, simon)
assert_equal('', result[:announcement])
assert_equal('Repeat. 6 sounds.', result[:status])
assert(!result[:header].include?('Repeat.'))
assert(!result[:header].include?('6 sounds.'))
assert(result[:instruction].include?('1 to 5'))
next_sequence = Marshal.load(Marshal.dump(simon))
next_sequence[:own][:level] = 7
result = project.call('simon', next_sequence, response)
assert_equal('', result[:announcement])
assert_equal('Listen. 7 sounds.', result[:status])
assert(!result[:header].include?('Listen.'))
assert(!result[:header].include?('7 sounds.'))
finished_sequence = Marshal.load(Marshal.dump(next_sequence))
finished_sequence[:own][:phase] = :finished
assert_equal('Waiting for others.', project.call('simon', finished_sequence, next_sequence)[:announcement])
finished_sequence[:finished] = true
assert_equal('Challenge finished.', project.call('simon', finished_sequence, next_sequence)[:announcement])
response[:own][:response_length] = 1
assert_equal('', project.call('simon', response, response)[:announcement])
assert_equal('', project.call('simon', response, blackjack)[:announcement], 'A different challenge must not be diffed')

puts 'PASS Duck challenge short announcements: pure deltas, full hand/pairs retained, phase transitions and no repeated title'
