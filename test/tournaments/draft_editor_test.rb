# encoding: UTF-8
require_relative '../support/ui'
require_relative '../../games/catalog'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/draft_editor.rb', __dir__)
require source if File.file?(source)

def assert(condition, message)
  raise message unless condition
end

assert(defined?(GameRoomTournaments::DraftEditor), 'Brakuje formularza szkicu turnieju')

module TournamentFormScript
  # Native src/ui/form.rb:562-568; keep the contract local to this light fake.
  def focus(*_arguments)
    control = fields[index]
    return unless control
    control.trigger(:before_focus)
    control.focus(index, fields.length)
    control.trigger(:focus)
  end

  def wait
    super
    action = $tournament_form_steps.shift
    raise 'Nieoczekiwany formularz' unless action
    action.call(self)
  end
end
Form.prepend(TournamentFormScript)

def field(form, header)
  form.fields.find { |control| control.respond_to?(:header) && control.header == header } || raise("Brakuje pola: #{header}")
end

def button(form, label)
  form.fields.find { |control| control.respond_to?(:label) && control.label == label } || raise("Brakuje przycisku: #{label}")
end

program = Object.new
registry = GameRoomGames::CATALOG
saved = []
alerts = []
$tournament_form_steps = [lambda do |form|
  assert(form.is_a?(GameRoomUI::Form), 'Formularz omija wspólny szkielet dostępności')
  assert(form.game_room_program.equal?(program), 'Formularz zgubił program')
  assert(form.fields[form.index].equal?(field(form, 'Tournament name')), 'Początkowy fokus nie jest w nazwie')
  assert(field(form, 'Tournament format').index == 1 && field(form, 'Return matches').index == 2,
    'Nowy turniej ma gotowe ustawienia każdy z każdym z rewanżem')
  field(form, 'Tournament name').text = 'Puchar jesienny'
  games = field(form, 'Game')
  assert(games.options.length == registry.ids.length + 1, 'Wybór nie obejmuje wszystkich gier i pustej pozycji')
  games.index = registry.ids.index('three_five_eight') + 1
  games.trigger(:move)
  field(form, 'Tournament format').index = 1
  field(form, 'Tournament format').trigger(:move)
  assert(form.instance_variable_get(:@hidden_controls).include?(field(form, 'Number of groups')), 'Pola grup przeszkadzają w formularzu ligi')
  field(form, 'Return matches').index = 2
  form.accept_button.trigger(:press)
end]
editor = GameRoomTournaments::DraftEditor.new(program: program, registry: registry,
  configure: ->(*) { raise 'Tworzenie nie powinno samo otwierać ustawień gry' },
  save: ->(attributes) { saved << attributes; attributes.merge('id' => 'saved') },
  alert: ->(message) { alerts << message })
result = editor.wait
assert(result['id'] == 'saved' && saved.length == 1, 'Szkic nie został przekazany do zapisu')
assert(saved.first == { 'name' => 'Puchar jesienny', 'game_id' => 'three_five_eight',
  'game_options' => registry.build('three_five_eight').default_options,
  'format' => 'round_robin', 'rematch' => true, 'participants' => [], 'windows' => [],
  'players_per_match' => nil, 'pairing' => nil, 'group_count' => nil, 'places_per_group' => nil, 'group_advancement' => nil }, 'Formularz pomylił dane turnieju z opcjami gry')
assert(alerts.empty? && $tournament_form_steps.empty?, 'Poprawny formularz zgłosił błąd')
puts 'PASS utworzenie szkicu przez dostępny formularz i pełny rejestr gier'

original = { 'name' => 'Poprzedni szkic', 'game_id' => 'three_five_eight',
  'game_options' => registry.build('three_five_eight').default_options.merge('bot_delay' => 3),
  'format' => 'groups_knockout', 'rematch' => false }
before = Marshal.dump(original)
configured = []
$tournament_form_steps = [lambda do |form|
  assert(field(form, 'Tournament name').text == original['name'], 'Edycja zgubiła zapisaną nazwę')
  assert(field(form, 'Game').index == registry.ids.index(original['game_id']) + 1, 'Edycja zgubiła grę')
  assert(field(form, 'Tournament format').index == 2 && field(form, 'Return matches').index == 1, 'Edycja zgubiła wariant turnieju')
  field(form, 'Tournament name').text = 'Niezapisane'
  button(form, 'Game settings').trigger(:press)
  form.cancel_button.trigger(:press)
end]
editor = GameRoomTournaments::DraftEditor.new(program: program, registry: registry, draft: original,
  configure: ->(game, options) { configured << [game.id, Marshal.load(Marshal.dump(options))]; options['bot_delay'] = 9; nil },
  save: ->(*) { raise 'Escape nie może zapisać szkicu' }, alert: ->(message) { raise message })
assert(editor.wait.nil?, 'Anulowanie zwróciło zapisany szkic')
assert(configured == [['three_five_eight', original['game_options']]], 'Edytor ustawień dostał niewłaściwą grę lub opcje')
assert(Marshal.dump(original) == before, 'Anulowanie zmieniło istniejący szkic lub jego opcje')
puts 'PASS edycja i anulowanie bez modyfikacji zapisanego szkicu'

saved.clear
alerts.clear
$tournament_form_steps = [lambda do |form|
  form.accept_button.trigger(:press)
  assert(saved.empty? && alerts.last == 'Enter a tournament name (1-120 characters, one line).', 'Pusta nazwa trafiła do zapisu')
  field(form, 'Tournament name').text = 'Poprawiony szkic'
  form.accept_button.trigger(:press)
  assert(saved.empty? && alerts.last == 'Select a game.', 'Brak gry trafił do zapisu')
  field(form, 'Game').index = registry.ids.index('chess') + 1
  form.accept_button.trigger(:press)
end]
editor = GameRoomTournaments::DraftEditor.new(program: program, registry: registry,
  configure: ->(*) { nil }, save: ->(attributes) { saved << attributes; attributes },
  alert: ->(message) { alerts << message })
editor.wait
assert(saved.length == 1 && saved.first['name'] == 'Poprawiony szkic', 'Walidacja zgubiła poprawiony formularz')
assert(saved.first.values_at('format', 'rematch') == ['round_robin', true], 'Poprawa błędów zgubiła ustawienia domyślne')
puts 'PASS poprawa błędów bez przebudowy formularza z zachowaniem ustawień domyślnych'

active = nil
attempts = 0
$tournament_form_steps = [lambda do |form|
  active = form
  field(form, 'Tournament name').text = 'Jednorazowy zapis'
  field(form, 'Game').index = registry.ids.index('chess') + 1
  form.accept_button.trigger(:press)
  assert(attempts == 1, 'Powtórne wejście uruchomiło drugi zapis')
  assert(form.instance_variable_get(:@wait) != false, 'Nieudany zapis zamknął edytor')
  assert(field(form, 'Tournament name').text == 'Jednorazowy zapis', 'Nieudany zapis zgubił tekst')
  form.accept_button.trigger(:press)
  form.accept_button.trigger(:press)
end]
editor = GameRoomTournaments::DraftEditor.new(program: program, registry: registry, configure: ->(*) { nil },
  alert: ->(message) { raise message }, save: lambda do |attributes|
    attempts += 1
    if attempts == 1
      active.accept_button.trigger(:press)
      active.accept_button.trigger(:press)
      active.cancel_button.trigger(:press)
      nil
    else
      attributes
    end
  end)
assert(editor.wait['name'] == 'Jednorazowy zapis' && attempts == 2, 'Ponowienie lub zamknięcie formularza wykonało nadmiarowy zapis')
puts 'PASS ochrona przed ponownym wejściem, zachowanie szkicu po błędzie i pojedynczy zapis'

window = { 'date' => '2026-10-02', 'start' => '18:00', 'end_date' => '2026-10-02', 'end' => '21:00' }
original = original.merge('participants' => %w[Ala Bartek Celina], 'windows' => [window],
  'players_per_match' => 3, 'pairing' => 'all_combinations')
before = JSON.generate(original)
parent_form = nil
saved.clear
$tournament_form_steps = [lambda do |form|
  parent_form = form
  button(form, 'Participants and playing windows').trigger(:press)
  assert(saved.empty?, 'Modalna konfiguracja pozwoliła na przedwczesny zapis szkicu')
  form.accept_button.trigger(:press)
end, lambda do |form|
  names = field(form, 'Participants (one name per line; local list)')
  assert(names.text.split(/\r?\n/) == original['participants'], 'Konfiguracja zgubiła uczestników')
  names.text = "Ala\r\nBartek\r\nCelina\r\nDarek"
  field(form, 'Multiplayer pairings').index = 2
  parent_form.accept_button.trigger(:press)
  parent_form.cancel_button.trigger(:press)
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftEditor.new(program: program, registry: registry, draft: original,
  configure: ->(*) { nil }, save: ->(attributes) { saved << attributes; attributes }, alert: ->(message) { raise message }).wait
assert(result['participants'] == %w[Ala Bartek Celina Darek] && result['pairing'] == 'balanced_cycle', 'Wybór organizatora nie dotarł do zapisu')
assert(result['windows'] == [window] && result['players_per_match'] == 3, 'Zapis zgubił okna lub liczbę graczy')
assert(saved.length == 1 && JSON.generate(original) == before, 'Zapis powielony lub zmutowany oryginał')
puts 'PASS integracja edytora szkicu z uczestnikami i oknami oraz blokada modalna'

saved.clear
original = original.merge('group_count' => 2, 'places_per_group' => 1)
before = Marshal.dump(original)
$tournament_form_steps = [lambda do |form|
  assert(field(form, 'Number of groups').index == 1, 'Nie przywrócono liczby grup')
  assert(!form.instance_variable_get(:@hidden_controls).include?(field(form, 'Number of groups')), 'Konfiguracja grup ukryta w formacie grupowym')
  assert(field(form, 'Qualifying places per group').index == 1, 'Nie przywrócono miejsc awansu')
  field(form, 'Number of groups').index = 3
  field(form, 'Qualifying places per group').index = 2
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftEditor.new(program: program, registry: registry, draft: original,
  configure: ->(*) { nil }, save: ->(attributes) { saved << attributes; attributes }, alert: ->(message) { raise message }).wait
assert(result['group_count'] == 4 && result['places_per_group'] == 2, 'Wybór ustawień grup nie dotarł do zapisu')
assert(Marshal.dump(original) == before, 'Edycja zmieniła oryginał przed zapisem')
puts 'PASS ustawienia grup: przywrócenie, zmiana i zapis bez mutowania szkicu'

$tournament_form_steps = [lambda do |form|
  field(form, 'Tournament name').text = 'Automatic groups'
  field(form, 'Game').index = registry.ids.index('tic_tac_toe') + 1
  field(form, 'Tournament format').index = 2
  field(form, 'Tournament format').trigger(:move)
  assert(field(form, 'Qualification policy').index == 0, 'New groups must default to automatic qualification')
  assert(form.instance_variable_get(:@hidden_controls).include?(field(form, 'Number of groups')), 'Automatic policy must derive group count from signup roster')
  form.accept_button.trigger(:press)
end]
result = GameRoomTournaments::DraftEditor.new(program: program, registry: registry,
  configure: ->(*) { nil }, save: ->(attributes) { attributes }, alert: ->(message) { raise message }).wait
assert(result['group_advancement'] == GameRoomTournaments::GroupAdvancement::COMPACT, 'Automatic policy lost during save')
assert(result['group_count'].nil? && result['places_per_group'].nil?, 'Automatic policy captured arbitrary group settings')
puts 'PASS new group draft defaults to roster-derived automatic qualification'
