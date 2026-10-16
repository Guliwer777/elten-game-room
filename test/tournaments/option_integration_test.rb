# encoding: UTF-8
require_relative '../support/game_option_form'
require_relative '../../lib/tournaments/draft_workspace'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })

registry = EltenGameRoom::GAME_REGISTRY
program = Object.new
workspace = GameRoomTournaments::DraftWorkspace.new(program: program, registry: registry,
  user: -> { 'Alice' }, alert: ->(message) { raise message }, confirm: ->(*) { true })
rummy = registry.build('rummy')
quiz = registry.build('quiz')
original = { 'name' => 'Ustawienia turnieju', 'game_id' => 'rummy',
  'game_options' => rummy.normalize_options('score_limit' => 1700), 'format' => nil, 'rematch' => nil }
before = JSON.generate(original)

def control(form, header)
  form.fields.find { |item| item.respond_to?(:header) && item.header == header } || raise("Brakuje kontrolki: #{header}")
end

def option(form, game, key)
  definition = game.effective_option_definitions.find { |item| item.key == key }
  control(form, definition.label)
end

steps = []
Form.driver = ->(form) { (steps.shift || raise('Nieoczekiwany formularz')).call(form) }
steps << lambda do |form|
  games = control(form, 'Game')
  settings = form.fields.find { |item| item.is_a?(Button) && item.label == 'Game settings' }
  assert(settings && form.game_room_program.equal?(program), 'Szkic nie używa wspólnego formularza programu')
  settings.trigger(:press)
  games.index = registry.ids.index('quiz') + 1
  settings.trigger(:press)
  games.index = registry.ids.index('rummy') + 1
  settings.trigger(:press)
  games.index = registry.ids.index('quiz') + 1
  settings.trigger(:press)
  games.index = registry.ids.index('rummy') + 1
  form.accept_button.trigger(:press)
end
steps << lambda do |form|
  assert(form.accept_button.label == 'Next', 'Przycisk ustawień szkicu sugeruje utworzenie stołu')
  score = option(form, rummy, 'score_limit')
  assert(score.text == '1700', 'Edytor nie otrzymał niestandardowych opcji szkicu')
  score.set_text('1500')
  elimination = option(form, rummy, 'elimination')
  elimination.checked = true
  elimination.trigger(:change)
  assert(score.text == '1500', 'Zmiana zależnej opcji nadpisała niestandardowy limit')
  form.accept_button.trigger(:press)
end
steps << lambda do |form|
  language_definition = quiz.effective_option_definitions.find { |item| item.key == 'content_language_id' }
  language = option(form, quiz, 'content_language_id')
  form.index = form.fields.index(language)
  language.index = language_definition.choices.index { |choice| choice.value == 'pl-PL' }
  language.trigger(:move)
  sets = control(form, 'Game content set')
  assert(sets.options.length == quiz.effective_option_definitions('content_language_id' => 'pl-PL').find { |definition| definition.key == 'content_set_id' }.choices.size, 'Zmiana języka w szkicu nie odświeżyła zestawów quizu')
  assert(form.fields[form.index].equal?(language), 'Zmiana języka odebrała fokus')
  sets.index = 1
  form.accept_button.trigger(:press)
end
steps << lambda do |form|
  score = option(form, rummy, 'score_limit')
  assert(score.text == '1500' && option(form, rummy, 'elimination').checked, 'Zmiana gry zgubiła ustawienia Remika')
  score.set_text('4444')
  form.cancel_button.trigger(:press)
end
steps << lambda do |form|
  language_definition = quiz.effective_option_definitions.find { |item| item.key == 'content_language_id' }
  language = option(form, quiz, 'content_language_id')
  assert(language_definition.choices[language.index].value == 'pl-PL', 'Powrót do quizu zgubił język')
  assert(control(form, 'Game content set').index == 1, 'Powrót do quizu zgubił zestaw pytań')
  form.accept_button.trigger(:press)
end
saved = GameRoomTournaments::DraftEditor.new(program: program, registry: registry, draft: original,
  configure: workspace.method(:configure), save: ->(attributes) { attributes }, alert: ->(message) { raise message }).wait
assert(steps.empty?, 'Nie wykonano całej ścieżki ustawień')
assert(saved['game_options']['score_limit'] == 1500 && saved['game_options']['elimination'], 'Anulowanie nadpisało ostatnio zatwierdzone ustawienia')
assert(saved['game_id'] == 'rummy' && JSON.generate(original) == before, 'Edytor zmienił oryginał szkicu lub grę')
puts 'PASS pełne połączenie edytor szkicu → kontroler → edytor opcji: Remik, quiz, przełączanie i anulowanie'
