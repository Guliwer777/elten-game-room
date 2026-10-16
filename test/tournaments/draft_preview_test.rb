# encoding: UTF-8
require_relative '../support/ui'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/draft_preview'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })

def assert(condition, message)
  raise message unless condition
end

module DraftPreviewScript
  # Wspólny lekki fake nie odtwarza Form#focus; kontrakt natywnego Form
  # skupia bieżące pole bez przestawiania kursora edytora.
  def focus(*_arguments)
    (@preview_focus_positions ||= []) << index
    fields[index]&.focus(index, fields.length)
  end

  def wait
    super
    action = $preview_steps.shift
    raise 'Nieoczekiwany formularz' unless action
    action.call(self)
  end
end
Form.prepend(DraftPreviewScript)

def field(form, header)
  form.fields.find { |control| control.respond_to?(:header) && control.header == header } || raise("Brakuje pola: #{header}")
end

def button(form, label)
  form.fields.find { |control| control.respond_to?(:label) && control.label == label } || raise("Brakuje przycisku: #{label}")
end

def draft(overrides = {})
  { 'name' => 'Żółty turniej', 'game_id' => 'three_five_eight', 'game_options' => {},
    'format' => 'round_robin', 'rematch' => false,
    'participants' => ['Żaneta', 'Łukasz', 'Аня', 'Zoë', '李'], 'windows' => [],
    'players_per_match' => 3, 'pairing' => 'all_combinations' }.merge(overrides)
end

def preview(row, steps, registry: GameRoomGames::CATALOG, alert: ->(message) { raise message })
  before = Marshal.dump(row)
  program = Object.new
  $preview_steps = steps
  GameRoomTournaments::DraftPreview.new(program: program, registry: registry, draft: row, alert: alert).wait
  assert($preview_steps.empty?, 'Nie wykonano wszystkich kroków')
  assert(Marshal.dump(row) == before, 'Podgląd zmienił szkic')
end

preview(draft('game_id' => 'rummy'), [lambda do |form|
  details = field(form, 'Tournament settings')
  assert(details.text.include?("Game settings:\r\n"), 'Opis zawiera dosłowne backslashe zamiast nowych wierszy')
  assert((details.flags & EditBox::Flags::ReadOnly) != 0, 'Ustawienia nie są tylko do odczytu')
  form.cancel_button.trigger(:press)
end])
puts 'PASS prawdziwe nowe wiersze i ustawienia tylko do odczytu'

class PreviewOptionsGame < GameRoomGames::Base
  def name; 'Próba — настройки'.b; end
  def option_definitions
    [GameRoomGames::OptionDefinition.new(key: 'enabled', label: 'Włączone'.b, kind: :boolean, default: true),
      GameRoomGames::OptionDefinition.new(key: 'time', label: 'Czas'.b, kind: :integer, default: 9, omit_zero: true, summary_unit: :seconds),
      GameRoomGames::OptionDefinition.new(key: 'choice', label: 'Wariant'.b, kind: :choice, default: 'a',
        choices: [GameRoomGames::OptionChoice.new(value: 'a', label: 'Łagodny — мир'.b)]),
      GameRoomGames::OptionDefinition.new(key: 'mask', label: 'Dodatki'.b, kind: :multiple_choice, default: 0,
        choices: [GameRoomGames::OptionChoice.new(value: 'x', label: 'Żeton'.b)]),
      GameRoomGames::OptionDefinition.new(key: 'hidden', label: 'Ukryte', kind: :integer, default: 17, visible_if: { 'enabled' => true })]
  end
  def normalize_options(values)
    values['nested']['items'] << 'zmiana tylko kopii' if values['nested']
    super(values)
  end
end
options_game = PreviewOptionsGame.new
options_registry = Struct.new(:game) { def build(_id); game; end }.new(options_game)
preview(draft('game_options' => { 'enabled' => false, 'time' => 0, 'nested' => { 'items' => [] } },
  'windows' => [{ 'date' => '2026-10-01', 'start' => '23:00', 'end_date' => '2026-10-02', 'end' => '02:30' }]),
  [lambda do |form|
    details = field(form, 'Tournament settings')
    content = details.text
    ['Żółty turniej', 'Próba — настройки', 'Local participants: 5', 'Żaneta', 'Łukasz', 'Аня', 'Zoë', '李',
      # Te same msgid co DraftDetailsEditor: celowe ujednolicenie terminologii, nie skrócenie opisu.
      '2026-10-01 23:00 to 2026-10-02 02:30', 'Players per match: 3', 'Multiplayer pairings: All possible compositions', 'Playing windows',
      'Tournament format: Round robin', 'Return matches: No', 'Włączone: No', 'Czas: 0 seconds',
      'Wariant: Łagodny — мир', 'Dodatki: None', 'not confirmed registrations', 'without time zone conversion'].each do |part|
      assert(content.include?(part), "Niepełny opis: #{part}")
    end
    assert(!content.include?('Ukryte'), 'Opis pokazuje nieużywaną opcję zależną')
    assert(content.encoding == Encoding::UTF_8 && content.valid_encoding?, 'Niepoprawne UTF-8 opisu')
    assert(details.text.b.force_encoding(Encoding::UTF_8).include?('Аня'), 'Usunięto Unicode')
    assert((details.flags & EditBox::Flags::ReadOnly) != 0, 'Opis pozwala na edycję')
    form.cancel_button.trigger(:press)
  end], registry: options_registry)
puts 'PASS pełny opis: uczestnicy, pełne daty, definicje opcji, false, zero, Unicode i kopia danych'

legacy = draft.reject { |key, _| %w[participants windows players_per_match pairing].include?(key) }
preview(legacy, [lambda do |form|
  content = field(form, 'Tournament settings').text
  # Także pusty stan używa wspólnej terminologii Playing windows.
  ['Local participants: 0', 'Players per match: To be decided', 'Multiplayer pairings: To be decided', 'No playing windows.'].each do |part|
    assert(content.include?(part), "Starszy szkic nie ma wartości domyślnej: #{part}")
  end
  form.cancel_button.trigger(:press)
end])
puts 'PASS starszy szkic używa nowych DEFAULTS bez uzupełniania zapisu'

require_relative '../../lib/tournaments/league_plan'
$preview_ui_thread = Thread.current
# Pilnuj wszystkich odczytów, zapisów i konstrukcji kontrolek, nie tylko wait.
ui_thread_check = TracePoint.new(:call, :c_call) do |event|
  next unless event.self.is_a?(FakeControl)
  assert(Thread.current == $preview_ui_thread, "Worker dotknął kontrolki: #{event.method_id}")
end
ui_thread_check.enable
module PreviewFormattingProbe
  def plan_text(matches)
    assert(Thread.current != $preview_ui_thread, 'Formatowanie planu blokuje UI')
    super
  end
end
GameRoomTournaments::DraftPreview.prepend(PreviewFormattingProbe)
$plan_calls = []
$task_calls = []
module PreviewPlanProbe
  def build(**arguments)
    $plan_calls << [arguments, Thread.current]
    $preview_worker_hook&.call
    super
  end
end
GameRoomTournaments::LeaguePlan.singleton_class.prepend(PreviewPlanProbe)
module PreviewTaskProbe
  def run(**options, &block)
    $task_calls << options
    super
  end
end
EltenAPI::Tasks.singleton_class.prepend(PreviewTaskProbe)
def loop_update
  $preview_tick&.call
  Thread.pass
end

[['all_combinations', false, 10, 6], ['balanced_cycle', false, 5, 3],
 ['all_combinations', true, 20, 12], ['balanced_cycle', true, 10, 6]].each do |pairing, rematch, count, appearances|
  row = draft('pairing' => pairing, 'rematch' => rematch)
  preview(row, [lambda do |form|
    # Terminologia celowo odpowiada DraftDetailsEditor także dla rotacji.
    pairing_label = pairing == 'balanced_cycle' ? 'Rotating compositions; equal appearances' : 'All possible compositions'
    assert(field(form, 'Tournament settings').text.include?("Multiplayer pairings: #{pairing_label}"), 'Inna terminologia doboru składów niż w edytorze')
    action = button(form, 'Match plan')
    assert(form.accept_button.equal?(action), 'Enter nie uruchamia planu')
    assert(!field(form, 'Tournament settings').key_processed(:enter), 'Opis pochłania Enter')
    action.trigger(:press)
    assert(form.instance_variable_get(:@wait) != false, 'Plan zamknął podgląd')
    form.cancel_button.trigger(:press)
  end, lambda do |form|
    assert(Thread.current == $preview_ui_thread, 'Widok powstał poza UI')
    matches = field(form, 'Matches')
    assert(matches.options.length == count, 'Błędna liczba spotkań')
    assert(matches.options.first == 'Match 1; leg 1; Żaneta, Łukasz, Аня', 'Nieprawidłowy skład lub numeracja')
    assert(matches.options.last.include?(rematch ? 'leg 2' : 'leg 1'), 'Nieprawidłowy rewanż')
    summary = field(form, 'Plan summary')
    assert((summary.flags & EditBox::Flags::ReadOnly) != 0, 'Podsumowanie nie jest tylko do odczytu')
    assert(summary.text.include?("Matches: #{count}"), 'Brak liczby spotkań')
    row['participants'].each { |name| assert(summary.text.include?("#{name}: #{appearances}"), 'Nierówne lub brakujące liczniki występów') }
    ['Local plan only', 'not confirmed registrations', 'Invitations and matches are not active',
      'no fixed start times', 'seats or roles', 'compositions and return matches only'].each do |part|
      assert(summary.text.include?(part), "Niejasny zakres planu: #{part}")
    end
    assert(form.fields.first.equal?(matches), 'Początkowy fokus nie jest na spotkaniach')
    form.cancel_button.trigger(:press)
  end])
  assert($plan_calls.last[1] != $preview_ui_thread, 'Plan obliczono na UI')
  assert($task_calls.last.values_at(:ui, :cancellable) == [:none, false], 'Zły kontrakt Tasks.run')
end
puts 'PASS lokalny plan 3-5-8: N5 K3, pełne 10/cykl 5, równe występy i rewanże w workerze'

def expect_plan_error(row, expected, before_build: false, registry: GameRoomGames::CATALOG)
  messages = []
  calls = $plan_calls.length
  preview(row, [lambda do |form|
    button(form, 'Match plan').trigger(:press)
    assert(messages == [expected], "Nieprawidłowy komunikat: #{messages.inspect}; oczekiwano #{expected.inspect}")
    assert(form.instance_variable_get(:@wait) != false, 'Błąd zamknął podgląd')
    form.cancel_button.trigger(:press)
  end], registry: registry, alert: lambda do |message|
    assert(Thread.current == $preview_ui_thread, 'Alert wykonano w workerze')
    messages << message
  end)
  assert($plan_calls.length == calls, 'Błędne dane dotarły do LeaguePlan.build') if before_build
end

expect_plan_error(draft('format' => nil), 'Choose the tournament format before building a match plan.', before_build: true)
puts 'PASS brak formatu wymaga ustawienia przed obliczeniem planu'

expect_plan_error(draft('format' => 'groups_knockout'), 'Choose the number of groups and qualifying places. Each group must have enough players for a match and fewer qualifying places than participants.')
puts 'PASS brak konfiguracji grup daje komunikat bez tworzenia niepełnego planu'

expect_plan_error(draft('game_id' => 'unknown_game'), 'Choose an available game before building a match plan.', before_build: true)
puts 'PASS nieznana gra nie trafia do planera'

expect_plan_error(draft('players_per_match' => 2), 'This game requires 3 to 3 players per match.', before_build: true)
puts 'PASS prawdziwe 3-5-8 nie jest planowane jako gra dwuosobowa'

expect_plan_error(draft('game_id' => 'axel_pong', 'players_per_match' => 2, 'game_options' => { 'team_size' => 2 }),
  'Doubles requires exactly four players.', before_build: true)
puts 'PASS rzeczywisty wariant debla Ponga odrzuca K2 mimo ogólnego minimum 2'

expect_plan_error(draft('players_per_match' => nil), 'Choose the number of players per match (2 to 8), not exceeding the participant count.')
puts 'PASS brak K daje czytelny komunikat i pozostawia podgląd'

expect_plan_error(draft('participants' => ['Jedna osoba']), 'Add 2 to 256 distinct local participants before building a match plan.')
puts 'PASS zbyt mało uczestników daje komunikat z kodu planera'

expect_plan_error(draft('pairing' => nil), 'Choose multiplayer pairings before building a match plan.')
puts 'PASS brak doboru składów'

expect_plan_error(draft('pairing' => 'bad'), 'Choose valid multiplayer pairings before building a match plan.')
puts 'PASS błędny dobór składów'

expect_plan_error(draft('rematch' => nil), 'Choose whether to include return matches before building a match plan.')
puts 'PASS brak decyzji o rewanżach'

expect_plan_error(draft('rematch' => 'bad'), 'Choose Yes or No for return matches before building a match plan.')
puts 'PASS błędna decyzja o rewanżach'

expect_plan_error(draft('participants' => Array.new(40) { |index| "Player #{index}" }), 'This plan exceeds 5000 matches. Reduce participants, change multiplayer pairings or disable return matches.')
puts 'PASS nadmierny plan bez otwierania listy'

active_preview = nil
alerts = []
preview(draft('format' => nil), [lambda do |form|
  active_preview = form
  button(form, 'Match plan').trigger(:press)
  assert(alerts.length == 1, 'Alert pozwolił otworzyć kolejny alert/planner')
  assert(form.instance_variable_get(:@wait) != false, 'Reentrant Back/Escape zamknął podgląd pod alertem')
  form.cancel_button.trigger(:press)
end], alert: lambda do |message|
  alerts << message
  if alerts.length == 1
    button(active_preview, 'Back').trigger(:press)
    active_preview.cancel_button.trigger(:press)
    button(active_preview, 'Match plan').trigger(:press)
  end
end)
puts 'PASS alert blokuje ponowne wejście w plan i Back/Escape'

alerts = []
preview(draft('format' => nil), [lambda do |form|
  form.cancel_button.trigger(:press)
  assert(form.instance_variable_get(:@wait) == false, 'Back/Escape nie zamknął podglądu')
  button(form, 'Match plan').trigger(:press)
  form.cancel_button.trigger(:press)
  assert(alerts.empty?, 'Zakończony podgląd obsługuje opóźnione akcje')
end], alert: ->(message) { alerts << message })
puts 'PASS finished odrzuca opóźnione akcje po zamknięciu podglądu'

[0, 1, 2].each do |focus_index|
  [:back, :escape].each do |close|
    preview(draft, [lambda do |form|
      form.index = focus_index
      details = field(form, 'Tournament settings')
      details.index, details.check = 12, 27
      button(form, 'Match plan').trigger(:press)
      assert(form.index == focus_index, 'Powrót z planu zgubił poprzednie pole')
      assert(form.instance_variable_get(:@preview_focus_positions)&.last == focus_index, 'Powrót nie przywrócił fokusu poprzedniemu polu')
      assert([details.index, details.check] == [12, 27], 'Powrót zresetował kursor lub zaznaczenie opisu')
      assert(form.instance_variable_get(:@wait) != false, 'Back/Escape planu zamknął podgląd')
      form.cancel_button.trigger(:press)
    end, lambda do |form|
      (close == :back ? button(form, 'Back') : form.cancel_button).trigger(:press)
      assert(form.instance_variable_get(:@wait) == false, 'Back/Escape nie zamknął samego planu')
    end])
  end
end
puts 'PASS Back/Escape osobnego planu przywraca dokładny fokus i kursor podglądu'

plan_keys = []
preview(draft('rematch' => true), [lambda do |form|
  2.times { button(form, 'Match plan').trigger(:press) }
  form.cancel_button.trigger(:press)
end, *Array.new(2) { lambda do |form|
  list = field(form, 'Matches')
  keys = list.instance_variable_get(:@item_keys)
  assert(keys && keys.length == 20 && keys.uniq.length == 20, 'Lista spotkań nie ma unikalnych stabilnych kluczy')
  plan_keys << keys.dup
  list.index = 6
  selected = keys[list.index]
  list.update_options(list.options.reverse, keys: keys.reverse)
  assert(list.instance_variable_get(:@item_keys)[list.index] == selected, 'Zmiana wierszy zgubiła tożsamość spotkania')
  form.cancel_button.trigger(:press)
end }])
assert(plan_keys[0] == plan_keys[1], 'Ponowne obliczenie tego samego planu zmieniło klucze spotkań')
puts 'PASS unikalne stabilne klucze spotkań, rewanżów i ponownego podglądu'

# Natywne Tasks.run: worker czeka na pojedynczy tick UI, bez timerów/sleep.
# Ten sam guard musi obejmować pompowanie UI, dialog planu i alert błędu workera.
[false, true].each do |invalid|
  calls, tasks = $plan_calls.length, $task_calls.length
  release = Queue.new
  ticked = false
  parent = nil
  messages = []
  $preview_worker_hook = -> { release.pop }
  $preview_tick = lambda do
    $preview_tick = nil
    ticked = true
    begin
      button(parent, 'Back').trigger(:press)
      parent.cancel_button.trigger(:press)
      button(parent, 'Match plan').trigger(:press)
      assert($task_calls.length == tasks + 1, 'Pump uruchomił drugie zadanie planera')
      assert(parent.instance_variable_get(:@wait) != false, 'Pump zamknął podgląd')
      parent.index = 2 # Symulacja zmiany nawigacji podczas pompowania UI.
    ensure
      release << true
    end
  end
  steps = [lambda do |form|
    parent = form
    form.index = 1
    button(form, 'Match plan').trigger(:press)
    assert(ticked, 'Nie przetestowano reentry z prawdziwego pump Tasks.run')
    assert(form.index == 1, 'Po pump nie odtworzono pola sprzed operacji')
    assert(form.instance_variable_get(:@wait) != false, 'Operacja zamknęła podgląd')
    assert(messages.length == (invalid ? 1 : 0), 'Nieprawidłowa liczba alertów')
    form.cancel_button.trigger(:press)
    button(form, 'Match plan').trigger(:press)
  end]
  unless invalid
    steps << lambda do |form|
      button(parent, 'Match plan').trigger(:press)
      button(parent, 'Back').trigger(:press)
      parent.cancel_button.trigger(:press)
      assert($task_calls.length == tasks + 1, 'Otwarty dialog dopuścił drugi plan')
      assert(parent.instance_variable_get(:@wait) != false, 'Dialog zamknął rodzica')
      form.cancel_button.trigger(:press)
    end
  end
  begin
    preview(draft('pairing' => invalid ? nil : 'all_combinations'), steps, alert: lambda do |message|
      assert(Thread.current == $preview_ui_thread, 'Błąd workera ogłoszono poza UI')
      messages << message
      button(parent, 'Match plan').trigger(:press)
      button(parent, 'Back').trigger(:press)
      parent.cancel_button.trigger(:press)
      assert($task_calls.length == tasks + 1, 'Alert błędu workera dopuścił drugi plan')
    end)
  ensure
    $preview_worker_hook = $preview_tick = nil
  end
  assert($plan_calls.length == calls + 1, 'Reentry lub finished powieliło plan')
end
puts 'PASS prawdziwy worker pump, dialog i alert błędu nie otwierają drugiego planu ani nie zamykają rodzica'

preview(draft, [lambda do |form|
  button(form, 'Match plan').trigger(:press)
  assert(form.instance_variable_get(:@wait) != false, 'Zamknięcie planu wznowiło rodzica')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  resumes = 0
  native_resume = form.method(:resume)
  form.define_singleton_method(:resume) do
    resumes += 1
    native_resume.call
    # Natywne Form#resume pompuje UI: opóźniony Escape może wejść ponownie.
    cancel_button.trigger(:press) if resumes == 1
  end
  form.cancel_button.trigger(:press)
  button(form, 'Back').trigger(:press)
  assert(resumes == 1, 'Zamknięty plan ponownie wywołuje resume/pump')
end])
puts 'PASS finished osobnego planu chroni pump przy powtórnym Back/Escape'

[ArgumentError.new('programming failure'), NoMethodError.new('missing method'),
 GameRoomTournaments::LeaguePlan::Invalid.new(:unrecognized_code)].each do |failure|
  alerts = []
  $preview_worker_hook = -> { raise failure }
  begin
    preview(draft, [lambda do |form|
      caught = nil
      begin
        button(form, 'Match plan').trigger(:press)
      rescue StandardError => error
        caught = error
      end
      assert(caught.equal?(failure), 'Zamaskowano lub zastąpiono błąd programu')
      assert(alerts.empty?, 'Błąd programu udaje błąd danych szkicu')
      $preview_worker_hook = nil
      button(form, 'Match plan').trigger(:press)
      form.cancel_button.trigger(:press)
    end, ->(form) { form.cancel_button.trigger(:press) }], alert: ->(message) { alerts << message })
  ensure
    $preview_worker_hook = nil
  end
end
puts 'PASS błędy programistyczne workera i nieznane kody nie są maskowane; guard zwalnia się po wyjątku'

failing_game = GameRoomGames::CATALOG.build('three_five_eight')
failure = ArgumentError.new('invalid game implementation')
failing_game.define_singleton_method(:validation_error) { |*_args, **_kwargs| raise failure }
failing_registry = Struct.new(:game) { def build(_id); game; end }.new(failing_game)
preview(draft, [lambda do |form|
  caught = nil
  begin
    button(form, 'Match plan').trigger(:press)
  rescue ArgumentError => error
    caught = error
  end
  assert(caught.equal?(failure), 'ArgumentError walidatora gry zamaskowany jako błędne ustawienia')
  form.cancel_button.trigger(:press)
end], registry: failing_registry)
puts 'PASS nieoczekiwany wyjątek walidatora gry zachowuje diagnostykę'

# Audyt wszystkich rzeczywistych definicji: podgląd nie może używać
# skróconego rules_options_text, który świadomie pomija false i omit_zero.
kinds = []
option_count = 0
GameRoomGames::CATALOG.ids.each do |game_id|
  game = GameRoomGames::CATALOG.build(game_id)
  options = game.normalize_options({})
  definitions = game.effective_option_definitions(options)
  preview(draft('game_id' => game_id, 'game_options' => options), [lambda do |form|
    lines = field(form, 'Tournament settings').text.split(/\r?\n/)
    definitions.each do |definition|
      kinds << definition.kind.to_sym
      next unless game.option_visible?(definition, options, normalize: false)
      value = options.fetch(definition.key.to_s, definition.default)
      expected = case definition.kind.to_sym
      when :boolean then value ? 'Yes' : 'No'
      when :integer then definition.summary_unit == :seconds ? "#{value} seconds" : value.to_s
      when :choice then definition.choices.find { |choice| choice.value.to_s == value.to_s }&.label.to_s
      when :multiple_choice
        labels = definition.choices.each_with_index.filter_map { |choice, index| choice.label if (value.to_i & (1 << index)) != 0 }
        labels.empty? ? 'None' : labels.join(', ')
      when :multiple_values
        labels = definition.choices.filter_map { |choice| choice.label if Array(value).map(&:to_s).include?(choice.value.to_s) }
        labels.empty? ? 'None' : labels.join(', ')
      else
        raise "Niezweryfikowany rodzaj opcji #{definition.kind} w #{game_id}"
      end
      label = GameRoomContent.utf8(definition.summary_label || definition.label)
      assert(lines.include?("#{label}: #{expected}"), "Podgląd pomija/skraca #{game_id}: #{definition.key}=#{value.inspect}")
      option_count += 1
    end
    form.cancel_button.trigger(:press)
  end])
end
assert(kinds.uniq.sort == [:boolean, :choice, :integer, :multiple_choice, :multiple_values], 'Nie przejrzano wszystkich rodzajów definicji opcji')
puts "PASS all #{GameRoomGames::CATALOG.ids.length} games: #{option_count} visible options; #{kinds.uniq.sort.join(', ')}"

preview(draft('game_options' => { 'mask' => 1, 'enabled' => true }), [lambda do |form|
  content = field(form, 'Tournament settings').text
  assert(content.include?('Dodatki: Żeton') && content.include?('Ukryte: 17') && content.include?('Włączone: Yes'), 'Wybrane multiple_choice lub aktywna zależność nie jest widoczna')
  form.cancel_button.trigger(:press)
end], registry: options_registry)
puts 'PASS wybrane multiple_choice i włączone opcje zależne'

expect_plan_error(draft('players_per_match' => 4), 'This game requires 3 to 3 players per match.', before_build: true)
expect_plan_error(draft('game_id' => nil), 'Choose an available game before building a match plan.', before_build: true)
expect_plan_error(draft('format' => 'other'), 'Choose the tournament format before building a match plan.', before_build: true)
expect_plan_error(draft('participants' => ['A', 'B']), 'Choose the number of players per match (2 to 8), not exceeding the participant count.')
expect_plan_error(legacy, 'Add 2 to 256 distinct local participants before building a match plan.')
puts 'PASS maksimum gry, brak gry, obcy format, N mniejsze od K i stary szkic'

preview(draft('game_id' => 'axel_pong', 'players_per_match' => 4, 'game_options' => { 'team_size' => 2 }),
  [lambda do |form|
    button(form, 'Match plan').trigger(:press)
    form.cancel_button.trigger(:press)
  end, lambda do |form|
    assert(field(form, 'Matches').options.length == 5, 'Legalny wariant debla Ponga nie jest planowany')
    form.cancel_button.trigger(:press)
  end])
puts 'PASS rzeczywisty wariant debla Ponga dopuszcza K4'

preview(draft('format' => 'groups_knockout', 'game_id' => 'chess', 'players_per_match' => 2,
  'participants' => %w[A B C D E F G], 'group_count' => 2, 'places_per_group' => 1),
  [lambda do |form|
    content = field(form, 'Tournament settings').text
    assert(content.include?('Number of groups: 2') && content.include?('Qualifying places per group: 1'), 'Opis zgubił konfigurację grup')
    button(form, 'Match plan').trigger(:press)
    form.cancel_button.trigger(:press)
  end, lambda do |form|
    assert(field(form, 'Matches').options.size == 9, 'Podgląd grup nie korzysta z planera')
    assert(field(form, 'Matches').options.first == 'Group 1; match 1; A, C', 'Niewłaściwa obsada grupy')
    summary = field(form, 'Plan summary').text
    assert(summary.include?('Group 1: A, C, E, G') && summary.include?('Group 2: B, D, F'), 'Brak składu grup w podsumowaniu')
    assert(summary.include?('Knockout matches require confirmed group results'), 'Podgląd udaje gotową drabinkę')
    assert(summary.include?('This is not a draw'), 'Brak wyjaśnienia podziału grup')
    form.cancel_button.trigger(:press)
  end])
puts 'PASS podgląd grup: ustawienia, składy, spotkania i jawny zakres dalszej fazy'

preview(draft('format' => 'groups_knockout', 'game_id' => 'chess', 'players_per_match' => 2,
  'participants' => %w[A B], 'group_advancement' => 'automatic_cross_groups_v1', 'rematch' => true),
  [lambda do |form|
    assert(field(form, 'Tournament settings').text.include?('Two participants play a direct final'), 'Brak opisu finalu')
    assert(field(form, 'Tournament settings').text.include?('Return matches: No'), 'Opis finalu sugeruje rewanze')
    button(form, 'Match plan').trigger(:press)
    form.cancel_button.trigger(:press)
  end, lambda do |form|
    assert(field(form, 'Matches').options.size == 1, 'Final powinien miec jeden mecz')
    form.cancel_button.trigger(:press)
  end])
puts 'PASS direct final native draft preview and no return match'

ui_thread_check.disable
puts 'PASS worker wyłącznie liczy i formatuje dane; żadne metody kontrolek nie działają poza UI'
