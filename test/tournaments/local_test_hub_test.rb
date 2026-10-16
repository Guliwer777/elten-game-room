# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
source = File.expand_path('../../lib/tournaments/local_test_hub.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::LocalTestHub), 'Brak LocalTestHub')
T = TournamentLocalHubTest
G = GameRoomTournaments
Form.prepend(T::Script)

program = Object.new
program.define_singleton_method(:data_path) { raise 'I/O przy wyborze aktora' }
args = T.args(program: program)
T.script(->(form) {
  assert(form.fields.first.text.include?('Test actor: RealOwner'), 'Brak automatycznego konta organizatora')
  form.cancel_button.trigger(:press)
}) { G::LocalTestHub.new(**args, clock: -> { 100 }).run }
puts 'PASS automatyczny organizator i Cancel bez I/O'

messages, actors = [], []
workspace = Object.new
workspace.define_singleton_method(:actor) { actors.last }
workspace.define_singleton_method(:mode_label) { 'Local test — this computer only' }
T.replace(G::LocalWorkspace, :new, ->(**values) {
  assert(values[:user].call == 'RealOwner', 'Zmieniono ownera na aktora')
  actors << values.fetch(:actor)
  workspace
}) do
  T.script(->(form) {
    T.button(form, 'Change test participant').trigger(:press)
    assert(form.fields.first.text.include?('Test actor: Testowa Alicja'), 'Brak aktora w hubie')
    T.button(form, 'Change test participant').trigger(:press)
    assert(form.fields.first.text.include?('Test actor: Testowy Bob'), 'Nie odświeżono jawnego aktora')
    form.cancel_button.trigger(:press)
  }, ->(form) {
   name = T.field(form, 'Test participant name')
    [' Alicja', 'Alicja ', '', "A\nB"].each do |invalid|
      name.text = invalid
      name.index, name.check = 1, 2
      T.button(form, 'Use test participant').trigger(:press)
      assert(name.text == invalid && [name.index, name.check] == [1, 2], 'Naprawiono tekst/kursor')
      assert(form.fields[form.index].equal?(name), 'Brak fokusu błędnej nazwy')
    end
    name.text = 'Testowa Alicja'
    T.button(form, 'Use test participant').trigger(:press)
  }, ->(form) {
    assert(T.field(form, 'Test participant name').text.empty?, 'Zmiana podsuwa wcześniejszą tożsamość')
    T.field(form, 'Test participant name').text = 'Testowy Bob'
    T.button(form, 'Use test participant').trigger(:press)
  }) { G::LocalTestHub.new(clock: -> { 100 }, **args.merge(alert: ->(message) { messages << message })).run }
end
assert(actors == ['RealOwner', 'Testowa Alicja', 'Testowy Bob'] && messages.length == 4, 'Walidacja/nowy workspace nie działają')
puts 'PASS ścisła nazwa bez naprawiania, tekst/caret/fokus i NOWY workspace przy zmianie'

owner = 'RealOwner'
messages = []
hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(user: -> { owner }, alert: ->(message) { messages << message }))
T.script(->(form) {
  T.button(form, 'Change test participant').trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  owner = 'OtherOwner'
  T.field(form, 'Test participant name').text = 'Alicja'
  T.button(form, 'Use test participant').trigger(:press)
  owner = 'RealOwner'
  T.button(form, 'Use test participant').trigger(:press)
  hub.run
  form.cancel_button.trigger(:press)
}) { hub.run }
assert(messages.all? { |message| message.include?('account changed') } && messages.length == 2, 'Nie zatrzaśnięto zmiany ownera')
puts 'PASS zmiana konta w dialogu zatrzaśnięta, run reentry nie resetuje guardu'

# Odczyt nil nie jest poprawną pustą listą; brak szkiców daje instrukcję.
[nil, []].each do |rows|
  messages = []
  hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(alert: ->(message) { messages << message }))
  T.with_drafts(rows) do
    T.script(->(form) {
      T.button(form, 'Publish a draft in local test').trigger(:press)
      form.cancel_button.trigger(:press)
    }) { hub.run }
  end
  assert(rows.nil? ? messages.empty? : messages.one? && messages.first.include?('previous menu'), 'nil odczytu udaje pusty sukces')
end
puts 'PASS nil szkiców zatrzymuje akcję; pusta lista prosi o utworzenie szkicu'

# Migawka powstaje PRZED taskiem operacji i przed pokazaniem edytora.
[nil, []].each do |operations|
  row = T.draft
  before = Marshal.dump(row)
  saved, messages = [], []
  hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(alert: ->(message) { messages << message }))
  steps = [->(form) {
    workspace = hub.instance_variable_get(:@workspace)
    workspace.define_singleton_method(:operations) do
      row['name'].replace('Zmieniono podczas odczytu')
      row['revision'] = 8
      row['game_options'].clear
      operations
    end
    workspace.define_singleton_method(:publish) { |**values| saved << values; {'status' => 'confirmed'} }
    T.button(form, 'Publish a draft in local test').trigger(:press)
    form.cancel_button.trigger(:press)
  }, ->(form) {
    T.button(form, 'Publish').trigger(:press)
    form.cancel_button.trigger(:press)
  }]
  unless operations.nil?
    steps << ->(form) {
      assert(form.fields.first.text.include?('Szkic — Łódź'), 'Nie zachowano snapshotu przed operacjami')
      TournamentPublicationEditorTest.fill(form)
      T.button(form, 'Publish in local test').trigger(:press)
    }
  end
  T.with_drafts([row]) { T.script(*steps) { hub.run } }
  if operations.nil?
    assert(saved.empty?, 'nil operacji otworzył nową publikację')
  else
    copy = saved.first.fetch(:draft)
    assert(copy == Marshal.load(before) && copy.frozen? && copy['game_options'].frozen?, 'Publikacja nie dostała głębokiej pierwotnej kopii')
    assert(saved.first[:intent_id] == "draft:#{copy['id']}:revision:7", 'Zamiar nie odpowiada snapshotowi')
    assert(saved.first[:timezone] == 'local_test:system' && saved.first[:registration_opens_at] == 100, 'Brak lokalnej konwersji')
  end
end
puts 'PASS nil operacji blokuje edytor; kopia i revision przed taskiem, właściwe keywordy i stały intent'

[[ 'id', 'nie-uuid' ], ['revision', 0], ['revision', '7'], ['revision', 2**63]].each do |key, invalid|
  messages = []
  row = T.draft.merge(key => invalid)
  hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(alert: ->(message) { messages << message }))
  T.with_drafts([row]) do
    T.script(->(form) {
      hub.instance_variable_get(:@workspace).define_singleton_method(:operations) { raise 'Operacje przed walidacją' }
      T.button(form, 'Publish a draft in local test').trigger(:press)
      form.cancel_button.trigger(:press)
    }, ->(form) {
      T.button(form, 'Publish').trigger(:press)
      form.cancel_button.trigger(:press)
    }) { hub.run }
  end
  assert(messages.one? && messages.first.include?('identity, revision'), 'Nie odrzucono ID/rewizji')
end
puts 'PASS walidacja UUID/revision przed odczytem operacji'

# Wąski adapter wyjątków; błąd programu nie jest błędem wpisanej daty.
hub = G::LocalTestHub.new(**args, clock: -> { 100 })
[:invalid_date, :invalid_time, :nonexistent_time, :invalid_timestamp, :ambiguous_time, :unsupported_time].each do |code|
  T.replace(G::LocalRegistrationTime, :convert, ->(*) { raise G::LocalRegistrationTime::Invalid, code }) do
    error = assert_raises(G::PublicationEditor::InvalidTime) { hub.send(:convert_time, 'date', 'time') }
    expected = [:ambiguous_time, :unsupported_time].include?(code) ? code : :invalid_time
    assert(error.code == expected, 'Zmieniono kod konwersji')
  end
end
[:unknown, :program].each do |mode|
  failure = mode == :unknown ? G::LocalRegistrationTime::Invalid.new(:unknown) : ArgumentError.new('Błąd programu')
  T.replace(G::LocalRegistrationTime, :convert, ->(*) { raise failure }) do
    error = assert_raises(ArgumentError) { hub.send(:convert_time, 'date', 'time') }
    assert(error.equal?(failure), 'Zamaskowano błąd programu') if mode == :program
  end
end
puts 'PASS mapowanie tylko LocalRegistrationTime::Invalid; nieznany kod i ArgumentError nie są połykane'

# Zmiana właściciela w edytorze blokuje save i wszystkie następne akcje huba.
owner, messages, calls = 'RealOwner', [], []
hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(user: -> { owner }, alert: ->(message) { messages << message }))
T.with_drafts([T.draft]) do
  T.script(->(form) {
    workspace = hub.instance_variable_get(:@workspace)
    workspace.define_singleton_method(:operations) { [] }
    workspace.define_singleton_method(:publish) { |**_| calls << :publish }
    T.button(form, 'Publish a draft in local test').trigger(:press)
    owner = 'RealOwner'
    T.button(form, 'Change test participant').trigger(:press)
    T.button(form, 'Browse local test tournaments').trigger(:press)
    T.button(form, 'Operations').trigger(:press)
    hub.run
    form.cancel_button.trigger(:press)
  }, ->(form) {
    T.button(form, 'Publish').trigger(:press)
    form.cancel_button.trigger(:press)
  }, ->(form) {
    owner = 'OtherOwner'
    TournamentPublicationEditorTest.fill(form)
    T.button(form, 'Publish in local test').trigger(:press)
    form.cancel_button.trigger(:press)
  }) { hub.run }
end
assert(calls.empty? && messages.any? { |message| message.include?('account changed') }, 'Zmiana właściciela wysłała publikację')
puts 'PASS zmiana ownera w edytorze: bez save i bez przepinania aktora po powrocie'

# Anulowanie zmiany uczestnika też sprawdza konto PO modalu.
owner, messages = 'RealOwner', []
hub = G::LocalTestHub.new(clock: -> { 100 }, **args.merge(user: -> { owner }, alert: ->(message) { messages << message }))
T.script(->(form) {
  T.button(form, 'Change test participant').trigger(:press)
  owner = 'RealOwner'
  T.button(form, 'Change test participant').trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  owner = 'OtherOwner'
  form.cancel_button.trigger(:press)
}) { hub.run }
assert(messages.any? { |message| message.include?('account changed') }, 'Cancel modalu zgubił zmianę konta')
puts 'PASS Cancel zmiany aktora nie pomija kontroli ownera po modalu'

[G::Publication::Invalid.new(:invalid_account), ArgumentError.new('program')].each do |error|
  messages = []
  T.replace(G::LocalWorkspace, :new, ->(**_) { raise error }) do
    action = -> { T.script { G::LocalTestHub.new(clock: -> { 100 }, **args.merge(alert: ->(message) { messages << message })).run } }
    if error.is_a?(G::Publication::Invalid)
      action.call
      assert(messages.one? && messages.first.include?('account or participant is invalid'), 'Brak kontrolowanego błędu konstruktora')
    else
      assert(assert_raises(ArgumentError, &action).equal?(error), 'Ukryto błąd konstruktora programu')
    end
  end
end
puts 'PASS konkretny Publication::Invalid konstruktora; ArgumentError propagowany'
