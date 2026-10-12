require_relative '../../support/duck_challenge_ui'
require_relative '../../../games/duck_racing_support/challenge_presentation'
include DuckChallengeTest

presentation = GameRoomDuckRacing::ChallengePresentation
kinds = GameRoomDuckRacing::Challenges::BY_ID.keys - ENGINE::REALTIME
assert_equal(16, kinds.length)
kinds.each do |kind|
  state = challenge_state(kind)
  view = ENGINE.view(state, seat: 0)
  before = Marshal.dump(view)
  projected = presentation.project(kind: kind, view: view, viewer: 0)
  assert_equal(before, Marshal.dump(view), "#{kind} presentation mutated the view")
  assert(!projected[:name].empty? && !projected[:header].empty?, "#{kind} lacks a prompt")
  assert(!projected[:instruction].empty? || projected[:auto_submit_length], "#{kind} lacks usable input instructions")
  assert_equal([:button, :list, :text].include?(projected[:mode]), true)
  assert(!projected.key?(:model) && !projected.key?(:answer) && !projected.key?(:correct_index))
  observer = presentation.project(kind: kind, view: ENGINE.view(state, seat: nil), viewer: nil)
  assert_equal(false, observer[:enabled], "#{kind} observer enabled input")
  assert(observer[:status].include?('watching'))
end

guess = challenge_state('guess_number')
assert(ENGINE.submit(guess, seat: 0, action: {kind: :answer, value: 1, press_id: 1}, now_ms: 1))
view = ENGINE.view(guess, seat: 0)
projected = presentation.project(kind: 'guess_number', view: view, viewer: 0)
assert(projected[:status].include?('higher') || projected[:status].include?('Waiting'))
assert(projected[:status].include?('9 attempts left') || projected[:status].include?('Waiting'))
assert(!projected[:header].include?('distance'), 'Hidden target distance entered the prompt')

question = challenge_state('race_question')
view = ENGINE.view(question, seat: 0)
view[:player_names] = {0 => 'Żółw'.b, 1 => 'Лена'.b}
header = presentation.project(kind: 'race_question', view: view, viewer: 0)[:header]
assert(header.include?('Żółw') || header.include?('Лена'), 'Provided public names were not used')

# Shorter instructions retain the actual input method and attempt budget. Repeated
# throws must not make every status read the entire history of the challenge.
{'guess_number' => 10, 'copy_number' => 3, 'arithmetic' => 3,
  'race_question' => 2, 'count_ducks' => 2}.each do |kind, limit|
  model = challenge_state(kind)
  view = ENGINE.view(model, seat: 0)
  projected = presentation.project(kind: kind, view: view, viewer: 0)
  assert(projected[:status].include?("#{limit} attempts left"), "#{kind} lost its current attempt budget")
  if projected[:auto_submit_length]
    assert(projected[:auto_submit_length].positive?, "#{kind} lost its automatic input width")
    assert(!projected[:instruction].include?('Enter'), "#{kind} still requires Enter")
    assert(!projected[:instruction].include?('automatically'), "#{kind} repeats the removed verbose instruction")
  else
    assert(projected[:instruction].include?('Enter'), "#{kind} lost its submit key")
  end
end
state = challenge_state('risky_dice')
view = ENGINE.view(state, seat: 0)
view[:turn_seat] = 0
view[:own].merge!(rolls: [[1, 2], [3, 4], [5, 6]], total: 21)
projected = presentation.project(kind: 'risky_dice', view: view, viewer: 0)
assert_equal('Roll: 5, 6. Total: 21.', projected[:status])
assert(projected[:instruction].include?('Down') && projected[:instruction].include?('Enter'))
view[:turn_seat] = 1
waiting = presentation.project(kind: 'risky_dice', view: view, viewer: 0)
assert_equal('Waiting for your turn. Roll: 5, 6. Total: 21.', waiting[:status])
assert_equal(false, waiting[:enabled])
assert_equal('1 attempt left.', presentation.attempts_left(1))
assert_equal('0 attempts left.', presentation.attempts_left(0))
{
  'sound_order' => ['1 to 8', 'Shift+digit'],
  'rhythm' => ['Enter', 'F', 'J', 'F5'],
  'sound_memory' => ['1 through 0'],
  'hit_duck' => ['1 to 9', 'left', 'centre', 'right'],
  'quiz' => ['1 to 4', 'arrow', 'Enter']
}.each do |kind, keys|
  instruction = presentation.description(kind)[1]
  keys.each { |key| assert(instruction.include?(key), "#{kind} lost #{key}") }
end

puts 'PASS Duck challenge presentation: all 16 real projections, controls, observer, private feedback and Unicode'
