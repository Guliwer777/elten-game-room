# encoding: UTF-8
require_relative '../support/ui'
require_relative '../../games/catalog'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/draft_screen.rb', __dir__)
require source if File.file?(source)

def assert(condition, message)
  raise message unless condition
end
assert(defined?(GameRoomTournaments::DraftScreen), 'Brakuje listy szkiców turniejów')

module TournamentScreenScript
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
    action = $tournament_screen_steps.shift
    raise 'Nieoczekiwany formularz' unless action
    action.call(self)
  end
end
Form.prepend(TournamentScreenScript)

def field(form, header)
  form.fields.find { |c| c.respond_to?(:header) && c.header == header } || raise("Brakuje pola: #{header}")
end

def button(form, label)
  form.fields.find { |c| c.respond_to?(:label) && c.label == label } || raise("Brakuje przycisku: #{label}")
end

program = Object.new
registry = GameRoomGames::CATALOG
rows = []
messages = []
$tournament_screen_steps = [lambda do |form|
  assert(form.game_room_program.equal?(program), 'Lista nie jest przypisana do programu')
  list = field(form, 'Tournament drafts')
  assert(form.fields[form.index].equal?(list), 'Początkowy fokus nie jest na liście')
  notice = field(form, 'Status')
  assert(notice.text.include?('not published') && notice.text.include?('this computer'), 'Lista nie wyjaśnia ograniczeń szkiców lokalnych')
  form.index = form.fields.index(button(form, 'New draft'))
  button(form, 'New draft').trigger(:press)
  assert(rows.length == 1 && list.options.first.include?('Próba lokalna'), 'Zapisany szkic nie pojawił się na tej samej liście')
  assert(form.fields[form.index].equal?(button(form, 'New draft')), 'Aktualizacja listy przesunęła fokus')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  field(form, 'Tournament name').text = 'Próba lokalna'
  field(form, 'Game').index = registry.ids.index('chess') + 1
  form.accept_button.trigger(:press)
end]
screen = GameRoomTournaments::DraftScreen.new(program: program, registry: registry,
  load: -> { Marshal.load(Marshal.dump(rows)) },
  persist: ->(existing, attributes) { raise 'Nowy szkic otrzymał istniejący rekord' if existing; rows << attributes.merge('id' => 'draft-1', 'revision' => 1); rows.last },
  remove: ->(*) { raise 'Nieoczekiwane usunięcie' }, configure: ->(*) { raise 'Nieoczekiwane ustawienia' },
  alert: ->(message) { messages << message }, confirm: ->(*) { raise 'Nieoczekiwane pytanie' })
screen.run
assert(messages == ['Draft saved locally. It has not been published.'], 'Brak jednoznacznego potwierdzenia lokalnego zapisu')
assert($tournament_screen_steps.empty?, 'Nie wykonano wszystkich kroków formularza')
puts 'PASS lista, utworzenie i powrót ze stabilnym fokusem; jawny lokalny status'

rows << rows.first.merge('id' => 'draft-2', 'name' => 'Drugi szkic')
fail_read = false
confirmed = false
removed = []
updated = []
$tournament_screen_steps = [lambda do |form|
  list = field(form, 'Tournament drafts')
  list.index = 1
  rows.reverse!
  button(form, 'Refresh').trigger(:press)
  assert(list.index == 0 && list.options[0].start_with?('Drugi szkic;'), 'Odświeżenie zgubiło tożsamość zaznaczonego szkicu')
  previous = list.options.dup
  fail_read = true
  button(form, 'Refresh').trigger(:press)
  assert(list.options == previous, 'Błąd odczytu wyczyścił poprawną listę')
  fail_read = false
  button(form, 'Edit draft').trigger(:press)
  assert(updated == [['draft-2', 1]] && list.options[list.index].start_with?('Zmieniony szkic;'), 'Przycisk Edytuj edytował zły szkic lub zgubił rewizję')
  button(form, 'Delete draft').trigger(:press)
  assert(removed.empty? && rows.length == 2, 'Odmowa potwierdzenia usunęła szkic')
  confirmed = true
  button(form, 'Delete draft').trigger(:press)
  assert(removed == [['draft-2', 2]] && rows.length == 1, 'Usunięto nieprawidłowy szkic lub użyto starej rewizji')
  assert(list.options.length == 1, 'Lista nie usunęła skasowanego wpisu')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  assert(field(form, 'Tournament name').text == 'Drugi szkic', 'Edycja otworzyła zły rekord')
  field(form, 'Tournament name').text = 'Zmieniony szkic'
  form.accept_button.trigger(:press)
end]
screen = GameRoomTournaments::DraftScreen.new(program: program, registry: registry,
  load: -> { fail_read ? nil : Marshal.load(Marshal.dump(rows)) },
  persist: lambda do |existing, attributes|
    updated << existing.values_at('id', 'revision')
    target = rows.find { |item| item['id'] == existing['id'] }
    target.merge!(attributes).merge!('revision' => 2)
  end,
  remove: ->(row) { removed << row.values_at('id', 'revision'); rows.reject! { |item| item['id'] == row['id'] }; true },
  configure: ->(*) { nil }, alert: ->(message) { messages << message }, confirm: ->(*) { confirmed })
screen.run
assert($tournament_screen_steps.empty?, 'Nie wykonano edycji')
puts 'PASS edycja, stabilne zaznaczenie, bezpieczny błąd odczytu i potwierdzenie usuwania'

active_form = nil
confirmations = 0
reads = 0
removed.clear
$tournament_screen_steps = [lambda do |form|
  active_form = form
  button(form, 'Delete draft').trigger(:press)
  assert(confirmations == 1 && removed.length == 1, 'Ponowne wejście powieliło potwierdzenie lub usunięcie')
  assert(form.instance_variable_get(:@wait) != false, 'Reentrant Escape zamknął listę podczas operacji')
  form.cancel_button.trigger(:press)
end]
screen = GameRoomTournaments::DraftScreen.new(program: program, registry: registry,
  load: -> { reads += 1; Marshal.load(Marshal.dump(rows)) }, persist: ->(*) { raise 'Nieoczekiwany zapis' },
  remove: ->(row) { removed << row['id']; rows.clear; true }, configure: ->(*) { nil },
  alert: ->(*) {}, confirm: lambda do |_message|
    confirmations += 1
    if confirmations == 1
      button(active_form, 'Delete draft').trigger(:press)
      button(active_form, 'Refresh').trigger(:press)
      active_form.cancel_button.trigger(:press)
    end
    true
  end)
screen.run
assert(reads == 1, 'Modalne potwierdzenie pozwoliło na równoległe odświeżenie')
puts 'PASS blokada ponownego wejścia podczas modalnego potwierdzenia'

read_count = 0
$tournament_screen_steps = [lambda do |form|
  button(form, 'New draft').trigger(:press)
  list = field(form, 'Tournament drafts')
  assert(list.options.length == 1 && list.options[0].start_with?('Potwierdzony;'), 'Błąd odświeżenia ukrył potwierdzony zapis')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  field(form, 'Tournament name').text = 'Potwierdzony'
  field(form, 'Game').index = registry.ids.index('chess') + 1
  form.accept_button.trigger(:press)
end]
GameRoomTournaments::DraftScreen.new(program: program, registry: registry,
  load: -> { read_count += 1; read_count == 1 ? [] : nil },
  persist: ->(_row, attributes) { attributes.merge('id' => 'confirmed', 'revision' => 1) },
  remove: ->(*) { false }, configure: ->(*) { nil }, alert: ->(*) {}, confirm: ->(*) { false }).run
puts 'PASS potwierdzony zapis pozostaje widoczny po błędzie ponownego odczytu'

preview_row = { 'id' => 'preview', 'revision' => 1, 'name' => 'Podgląd', 'game_id' => 'rummy',
  'game_options' => registry.build('rummy').normalize_options('score_limit' => 1700), 'format' => 'round_robin', 'rematch' => false }
original_preview = JSON.generate(preview_row)
$tournament_screen_steps = [lambda do |form|
  list = field(form, 'Tournament drafts')
  before_index = list.index
  assert(form.accept_button.label == 'View draft', 'Enter nadal otwiera edycję zamiast podglądu')
  form.accept_button.trigger(:press)
  assert(form.fields[form.index].equal?(list) && list.index == before_index, 'Podgląd zgubił zaznaczenie lub fokus listy')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  details = field(form, 'Tournament settings')
  assert(details.text.include?('Podgląd') && details.text.include?('1700'), 'Podgląd nie pokazuje zapisanych ustawień')
  assert(details.instance_variable_get(:@type) & EditBox::Flags::ReadOnly != 0, 'Podgląd nie jest tylko do odczytu')
  assert(form.fields.none? { |item| item.respond_to?(:label) && item.label == 'Save draft' }, 'Podgląd zawiera zapis')
  form.cancel_button.trigger(:press)
end]
GameRoomTournaments::DraftScreen.new(program: program, registry: registry,
  load: -> { [preview_row] }, persist: ->(*) { raise 'Enter zapisał szkic' },
  remove: ->(*) { raise 'Enter usunął szkic' }, configure: ->(*) { raise 'Enter otworzył edycję ustawień' },
  alert: ->(message) { raise message }, confirm: ->(*) { raise 'Enter wywołał potwierdzenie' }).run
assert(JSON.generate(preview_row) == original_preview, 'Podgląd zmienił szkic')
puts 'PASS Enter otwiera podgląd bez zapisu, a Edytuj pozostaje oddzielnym działaniem'
