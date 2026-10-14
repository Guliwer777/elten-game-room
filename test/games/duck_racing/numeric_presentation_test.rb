require_relative '../../support/duck_challenge_ui'
require_relative '../../support/localization'
require_relative '../../../games/duck_racing_support/challenge_presentation'
include DuckChallengeTest

presentation = GameRoomDuckRacing::ChallengePresentation
languages = {
  'en' => ['Number from 1 to 999.', 'F5 repeats the sounds.', ['Answer: 1 digit.', 'Answer: 2 digits.', 'Answer: 3 digits.', 'Answer: 5 digits.']],
  'pl' => ['Liczba od 1 do 999.', 'F5 powtarza dźwięki.', ['Odpowiedź: 1 cyfra.', 'Odpowiedź: 2 cyfry.', 'Odpowiedź: 3 cyfry.', 'Odpowiedź: 5 cyfr.']],
  'cs' => ['Číslo od 1 do 999.', 'F5 zopakuje zvuky.', ['Odpověď: 1 číslice.', 'Odpověď: 2 číslice.', 'Odpověď: 3 číslice.', 'Odpověď: 5 číslic.']],
  'es' => ['Número del 1 al 999.', 'F5 repite los sonidos.', ['Respuesta: 1 cifra.', 'Respuesta: 2 cifras.', 'Respuesta: 3 cifras.', 'Respuesta: 5 cifras.']],
  'ru' => ['Число от 1 до 999.', 'F5 повторяет звуки.', ['Ответ: 1 цифра.', 'Ответ: 2 цифры.', 'Ответ: 3 цифры.', 'Ответ: 5 цифр.']]
}

languages.each do |language, (range, repeat, hints)|
  GameRoomTestLocalization.use_language(language)
  [1, 2, 3, 5].each_with_index do |digits, index|
    assert_equal(hints[index], presentation.digit_hint('guess_number', {answer_digits: digits}), language)
  end
  %w[copy_number guess_number arithmetic race_question count_ducks].each do |kind|
    model = challenge_state(kind)
    view = ENGINE.view(model, seat: 0)
    output = presentation.project(kind: kind, view: view, viewer: 0)
    name, instruction, = presentation.description(kind)
    expected_instruction = {'guess_number' => range, 'count_ducks' => repeat}.fetch(kind, '')
    assert_equal(expected_instruction, instruction, "#{language}: no repeated auto-submit explanation for #{kind}")
    hint = presentation.digit_hint(kind, view)
    assert_equal([expected_instruction, hint].reject(&:empty?).join(' '), output[:instruction])
    assert_equal(presentation.answer_digits(kind, view), output[:auto_submit_length])

    expected = case kind
    when 'count_ducks' then '' # Do not speak over the ducks.
    when 'guess_number' then [range, hint].join(' ')
    when 'copy_number' then presentation.prompt(kind, view)
    else [presentation.prompt(kind, view), hint].join(' ')
    end
    assert_equal(expected, output[:announcement], "#{language}: concise initial #{kind}")
    assert_equal('', presentation.project(kind: kind, view: view, viewer: 0, previous_view: view)[:announcement])
    next unless kind == 'count_ducks'

    acknowledge_challenge(model)
    responding = ENGINE.view(model, seat: 0)
    assert_equal(hint, presentation.project(kind: kind, view: responding, viewer: 0, previous_view: view)[:announcement])
    assert_equal('', presentation.project(kind: kind, view: responding, viewer: 0, previous_view: responding)[:announcement])
  end
end
puts 'PASS concise numeric prompts in all five languages, digit hints and count playback transition'
