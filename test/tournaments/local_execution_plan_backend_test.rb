# encoding: UTF-8
require_relative '../support/tournament_local_execution_plan'
require_relative '../support/tournament_time'
include TournamentLocalExecutionPlanSupport
file = File.expand_path('../../lib/tournaments/local_execution_plan_backend.rb', __dir__)
require file if File.file?(file)

def test_accepts_explicit_base_seats_and_reads_same_plan_after_reopen
  with_fixture do |f|
    assert(GameRoomTournaments.const_defined?(:LocalExecutionPlanBackend), 'Brak producenta trwałej lokalnej akceptacji jawnej obsady')
    original = f.author_service.schedule_candidate(publication_ref: f.reference).to_h
    base = f.base
    assert_equal(%w[beta alpha], base.values.first, 'Baza musi być przeciwna sortowaniu źródła')
    backend = f.backend
    shown = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'jawna-intencja-1')
    record = backend.accept(preview: shown)
    bytes = File.binread(File.join(f.directory,'k02','sandbox-k02.json'))
    reopened = f.backend
    again = reopened.readback(intent_id: 'jawna-intencja-1')
    assert_equal(record, again, 'Nowa instancja odczytuje ten sam pełny rekord z dysku')
    assert_equal(bytes, File.binread(File.join(f.directory,'k02','sandbox-k02.json')), 'Readback nie zapisuje generacji')
    evidence = record.fetch('evidence')
    assert_equal(original['matches'].map { |m| m.values_at('match_id','leg','players') }, evidence['source']['matches'].map { |m| m.values_at('match_id','leg','accounts') }, 'Źródłowe ID, leg i kolejność bez zmian')
    assert_equal(2, evidence['plan']['matches'].size, 'Oba istniejące legi')
    evidence['plan']['matches'].each do |match|
      value = request(again, match)
      expected = match['leg'] == 1 ? %w[beta alpha] : %w[alpha beta]
      assert_equal(expected, value['players'].map { |p| p['account'] }, 'Zatwierdzona kolejność i zamiana w rewanżu')
      assert_equal([0,1], value['players'].map { |p| p['seat'] }, 'Miejsca zerowe')
      assert_equal(%w[w b], value['players'].map { |p| p['game_role'] }, 'Natywne kolory szachów')
      assert_equal(['player','player'], value['players'].map { |p| p['role'] })
      assert_equal([nil,nil], value['players'].map { |p| p['team'] })
      assert_equal([], value['observers'])
      assert_equal(original['game_options'], value['options'])
      assert_equal(evidence['source']['windows'], match['windows'])
    end
    assert_equal(record, reopened.current(intent_id: 'jawna-intencja-1'))
    assert(record.frozen? && record['evidence']['plan']['matches'].first['players'].all?(&:frozen?), 'Pełny zamrożony odłączony wynik')
  end
end

test_accepts_explicit_base_seats_and_reads_same_plan_after_reopen
puts 'PASS test_accepts_explicit_base_seats_and_reads_same_plan_after_reopen'

with_fixture(names: %w[Beta Alpha Gamma]) do |f|
  backend = f.backend
  base = f.base
  variants = [base.merge('obcy-mecz' => %w[beta alpha]), base.reject { |k, _| k == base.keys.first },
    nil, [], base.merge(base.keys.first => %w[alpha alpha]), base.merge(base.keys.first => ['alpha', 'obce']),
    base.merge(base.keys.first => 'alpha')]
  variants.each do |invalid|
    error = assert_raises(GameRoomTournaments::Publication::Invalid) do
      backend.preview(publication_ref: f.reference, base_seats: invalid, intent_id: 'zla-baza')
    end
    assert_equal(:invalid_base_seats, error.code, 'Odmowa CAŁEJ niepełnej lub błędnej bazy')
    assert(!File.exist?(File.join(f.directory,'k02','sandbox-k02.json')), 'Nie wolno utrwalić części planu')
  end
  shown = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'pelne-pary')
  record = backend.accept(preview: shown)
  assert_equal(6, record['evidence']['plan']['matches'].length, 'Trzy osoby dają trzy pary oraz istniejące rewanże')
  record['evidence']['plan']['matches'].each { |m| request(record, m) }
end
puts 'PASS pełne pokrycie jawnej bazy oraz wiele par'

# Card games use the same declared seat contract, without an id allowlist.
with_fixture(game: 'war') do |f|
  shown = f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'inna-rodzina')
  record = f.backend.accept(preview: shown)
  assert_equal(%w[seat:0 seat:1], record['evidence']['plan']['matches'].first['players'].map { |p| p['game_role'] })
end
puts 'PASS game-declared roles for card games'

with_fixture(names: ['İ' * 64, 'Beta', 'Alpha'], rematch: false) do |f|
  reference, base, intent = JSON.parse(JSON.generate(f.reference)), f.base, +'oddzielone-wejscie'
  expected = JSON.parse(JSON.generate(base))
  callback = lambda do
    reference['author'].replace('KtosInny')
    base.clear
    intent.replace('zmieniony-intent')
  end
  registry = Object.new
  registry.define_singleton_method(:build) do |id|
    action, callback = callback, nil
    action&.call
    GameRoomGames::CATALOG.build(id)
  end
  backend = f.backend(registry: registry)
  shown = backend.preview(publication_ref: reference, base_seats: base, intent_id: intent)
  assert_equal(expected, shown['base_seats'], 'Kopie PRZED callbackiem registry')
  assert_equal('oddzielone-wejscie', shown['intent_id'])
  assert(!reference.frozen? && !base.frozen? && !intent.frozen?, 'Nie zamrażać caller')
  result = backend.accept(preview: shown)
  assert_equal(3, result['evidence']['plan']['matches'].size, 'Brak rematch nie dopisuje leg2')
  assert_equal([1], result['evidence']['plan']['matches'].map { |m| m['leg'] }.uniq)
  person = result['evidence']['source']['roster'].find { |p| p['username'] == 'İ' * 64 }
  assert_equal(('İ' * 64).downcase, person['account'], 'Raw i rozwinięte canonical Unicode pozostają różne')
end
puts 'REGRESJA PASS brak rewanżu, Unicode i detach podczas registry'

with_fixture do |f|
  backend = f.backend
  base = f.base
  first = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'pierwsza')
  record = backend.accept(preview: first)
  path = File.join(f.directory,'k02','sandbox-k02.json')
  bytes = File.binread(path)
  assert_equal(record, f.backend.accept(preview: first), 'Idempotentne ponowienie na drugiej instancji')
  assert_equal(bytes, File.binread(path), 'Retry nie przepisuje magazynu')
  f.now += 5
  second = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'druga')
  assert_equal(record, f.backend.accept(preview: second), 'Inna intencja tego samego źródła zwraca pierwszy plan')
  assert_equal(record, f.backend.readback(intent_id: 'druga'), 'Alias intencji trwały po ponownym otwarciu')
  reversed = base.transform_values(&:reverse)
  changed = backend.preview(publication_ref: f.reference, base_seats: reversed, intent_id: 'pierwsza')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: changed) }
  assert_equal(:intent_conflict, error.code)
  changed = backend.preview(publication_ref: f.reference, base_seats: reversed, intent_id: 'trzecia')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: changed) }
  assert_equal(:source_conflict, error.code)
  assert_equal(1, JSON.parse(File.binread(path))['records'].size, 'Nie powstał drugi plan')
end
puts 'PASS trwała idempotencja dwóch instancji, aliasy intencji i konflikty obsady'

with_fixture do |f|
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'stare-zrodlo')
  record = backend.accept(preview: shown)
  path = File.join(f.directory,'k02','sandbox-k02.json')
  bytes = File.binread(path)
  f.actor = 'Beta'
  f.tables.fetch('tournament_registrations').insert(GameRoomTournaments::RegistrationProjection.join_values(tournament_id: 1, operation_key: SecureRandom.uuid))
  f.actor = 'Organizator'
  assert_equal(record, f.backend.readback(intent_id: 'stare-zrodlo'), 'Historia zachowuje pierwotną intencję')
  [:current, :accept].each do |action|
    error = assert_raises(GameRoomTournaments::Publication::Invalid) do
      action == :current ? backend.current(intent_id: 'stare-zrodlo') : backend.accept(preview: shown)
    end
    assert_equal(:source_changed, error.code, 'Historyczny plan nie nadaje prawa nowej mutacji')
  end
  assert(bytes == File.binread(path), 'Zmiana źródła nie nadpisuje planu')
end
puts 'PASS świeże źródło oddzielone od historycznego exact readback'

with_fixture do |f|
  base = f.base
  f.actor = 'Beta'
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'nie-autor')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: shown) }
  assert_equal(:not_author, error.code)
  assert(!File.exist?(File.join(f.directory,'k02','sandbox-k02.json')))
end
puts 'PASS akceptacja wyłącznie autora publikacji'

with_fixture do |f|
  fake = Object.new
  fake.define_singleton_method(:backend_identity) { f.tables.backend_identity }
  fake.define_singleton_method(:local_test?) { true }
  error = assert_raises(GameRoomTournaments::Publication::Invalid) do
    GameRoomTournaments::LocalExecutionPlanBackend.new(directory: File.join(f.directory,'fake'), tables: fake,
      journal: f.journal, actor: f.actor, registry: GameRoomGames::CATALOG, clock: -> { f.now })
  end
  assert_equal(:invalid_composition, error.code, 'Sam prefiks i local_test? nie są zaufanym adapterem')
end
puts 'PASS rzeczywisty adapter i przypięta kompozycja'

with_fixture do |f|
  backend = f.backend(context: nil)
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'bez-autorytetu')
  assert(shown['source']['candidate']['matches'].size == 2, 'Brak autorytetu nie blokuje publicznego odczytu')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: shown) }
  assert_equal(:context_unavailable, error.code)
end
puts 'REGRESJA PASS publiczny odczyt bez prawa mutacji'

[:actor, :backend, :owner].each do |change|
  with_fixture do |f|
    base = f.base
    fired = false
    registry = Object.new
    registry.define_singleton_method(:build) do |id|
      unless fired
        fired = true
        case change
        when :actor
          f.session.choose_actor('Beta'); f.session.choose_actor('Organizator')
        when :backend
          previous = f.session.backend_events.snapshot[:value]
          f.session.change_backend('inny-backend'); f.session.change_backend(previous)
        when :owner
          f.owner = 'InnyWlasciciel'
        end
      end
      GameRoomGames::CATALOG.build(id)
    end
    backend = f.backend(registry: registry)
    error = assert_raises(StandardError) { backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'aba') }
    assert(error.respond_to?(:code) && [:context_changed, :account_changed].include?(error.code), 'Zmiana kontekstu ma precyzyjny powód odmowy')
    assert(fired && !File.exist?(File.join(f.directory,'k02','sandbox-k02.json')), 'Zmiana kontekstu podczas źródła blokuje użycie')
  end
end
puts 'PASS emitowane ABA aktora/backendu i oddzielny właściciel plików podczas callbacka'

with_fixture do |f|
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'relacje')
  tampered = JSON.parse(JSON.generate(shown))
  tampered['assignments'].last['players'].each { |p| p['game_role'] = p['seat'] == 0 ? 'b' : 'w' }
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: tampered) }
  assert_equal(:invalid_preview, error.code, 'Dowolny Hash podglądu nie jest zatwierdzoną obsadą')
  record = backend.accept(preview: shown)
  path = File.join(f.directory,'k02','sandbox-k02.json')
  original = File.binread(path)
  mutations = [
    ->(r) { r['preview']['base_seats'].values.first.reverse! },
    ->(r) { r['approval']['actor'] = 'beta' },
    ->(r) { r['request_digests'].values.last.transform_values! { '0' * 64 } },
    ->(r) { r['preview']['source']['candidate']['matches'].last['leg'] = 1 },
    ->(r) do
      r['evidence']['plan']['matches'].last['players'].each { |p| p['game_role'] = p['seat'] == 0 ? 'b' : 'w' }
      r['evidence']['plan_digest'] = GameRoomTournaments::ExecutionPlanContract.digest(r['evidence'].slice('scope','plan'))
    end
  ]
  mutations.each do |mutate|
    document = JSON.parse(original)
    mutate.call(document['records'].first)
    changed = JSON.generate(document)
    File.binwrite(path, changed)
    error = assert_raises(GameRoomTournaments::Publication::Invalid) { f.backend.readback(intent_id: 'relacje') }
    assert_equal(:sandbox_corrupt, error.code, 'Relacje całego rekordu, również niewybranego rewanżu')
    assert(changed.b == File.binread(path), 'Odczyt nie naprawia uszkodzenia')
    File.binwrite(path, original)
  end
  assert_equal(record, f.backend.readback(intent_id: 'relacje'))
end
puts 'PASS spójność podglądu/źródła/bazy/approval/requestów i całego niewybranego rewanżu'

with_fixture(names: (1..17).map { |i| "Gracz#{i}" }) do |f|
  candidate = f.author_service.schedule_candidate(publication_ref: f.reference).to_h
  assert_equal(272, candidate['matches'].size, 'Rzeczywisty kandydat większy od A, lecz legalny dla planera')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) do
    f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'nadmierny-plan')
  end
  assert_equal(:execution_plan_limit, error.code)
  assert(!File.exist?(File.join(f.directory,'k02','sandbox-k02.json')), 'Bez truncacji ani częściowego zatwierdzenia')
end
puts 'PASS odmowa całego kandydata przekraczającego 256 spotkań'

with_fixture do |f|
  backend = f.backend
  first = backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'pierwszy-turniej'))
  f.now = 150
  operation = f.author_service.publish(**params('chess', draft: draft.merge('rematch' => true), intent_id: 'druga-publikacja', timezone: 'local_test:system'))
  assert_equal('confirmed', operation['status'])
  reference = {'author' => 'Organizator', 'publication_key' => operation['values']['publication_key']}
  row = f.author_service.list['announcements'].find { |r| r['publication_key'] == reference['publication_key'] }
  %w[BETA ALPHA].each do |actor|
    f.actor = actor
    assert_equal('confirmed', f.service(f.journal_for(actor)).join(tournament_id: row['__id'])['status'])
  end
  f.actor, f.now = 'Organizator', 201
  candidate = f.author_service.schedule_candidate(publication_ref: reference).to_h
  base = candidate['matches'].select { |m| m['leg'] == 1 }.to_h { |m| [m['match_id'], m['players'].reverse] }
  record = backend.accept(preview: backend.preview(publication_ref: reference, base_seats: base, intent_id: 'drugi-turniej'))
  assert_equal(%w[ALPHA BETA], record['evidence']['source']['roster'].map { |p| p['username'] }, 'Members należą do wskazanej publikacji, nie całej tabeli')
  assert_equal(first, backend.readback(intent_id: 'pierwszy-turniej'), 'Stary dowód nie został nadpisany')
  path = File.join(f.directory,'k02','sandbox-k02.json')
  document = JSON.parse(File.binread(path))
  document['records'].first['approval']['actor'] = 'obcy'
  File.binwrite(path, JSON.generate(document))
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.readback(intent_id: 'drugi-turniej') }
  assert_equal(:sandbox_corrupt, error.code, 'Uszkodzony NIEWYBRANY rekord blokuje cały magazyn')
end
puts 'PASS dwa turnieje, właściwe raw members oraz korupcja niewybranego rekordu'

with_fixture do |f|
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'limity')
  backend.accept(preview: shown)
  path = File.join(f.directory,'k02','sandbox-k02.json')
  original = File.binread(path)
  {'records' => 9, 'intents' => 4097}.each do |key, count|
    document = JSON.parse(original)
    document[key] = Array.new(count) { document[key].first }
    File.binwrite(path, JSON.generate(document))
    error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.readback(intent_id: 'limity') }
    assert_equal(:sandbox_limit, error.code, 'Limit liczności przed kosztowną walidacją elementów')
  end
  File.binwrite(path, original)
end
puts 'PASS ścisły limit rekordów i aliasów całego magazynu'

with_fixture do |f|
  original = f.tables.method(:select_rows)
  reads, logical_reads = [], []
  f.tables.define_singleton_method(:select_rows) { |name, *args, **kwargs| reads << name; original.call(name, *args, **kwargs) }
  trace = TracePoint.new(:call) do |event|
    logical_reads << event.binding.local_variable_get(:table_name) if event.defined_class == T::TablesGateway && event.method_id == :read_rows
  end
  begin
    trace.enable(target_thread: nil)
    source = f.author_service.execution_source(publication_ref: f.reference)
  ensure
    trace.disable
  end
  assert_equal(%w[tournament_announcements tournament_registrations], logical_reads, 'Jeden cykl dwóch odczytów bramki, nie transakcja')
  assert_equal(%w[tournament_announcements tournament_announcements tournament_registrations tournament_registrations], reads, 'Rzeczywiste strony i kontrola granicy paginacji')
  assert_equal(%w[Alpha Beta], source['projection']['members'].map { |m| m['username'] })
  shown = f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'baza-konflikt')
  backend = f.backend
  record = backend.accept(preview: shown)
  other = backend.preview(publication_ref: f.reference, base_seats: f.base.transform_values(&:reverse), intent_id: 'inne-uuid')
  error = assert_raises(GameRoomTournaments::Publication::Invalid) { backend.accept(preview: other) }
  assert_equal(:source_conflict, error.code)
  require_relative '../../lib/tournaments/coordination_service'
  directory = File.join(f.directory,'bez-portu')
  service = GameRoomTournaments::CoordinationService.new(port: nil, trusted_identity: backend.identity,
    directory: directory, registry: GameRoomGames::CATALOG, context: nil)
  outcome = service.request_match(request: request(record, record['evidence']['plan']['matches'].first))
  assert_equal(:missing_port, outcome[:reason])
  assert_equal(:coordination_unavailable, outcome[:state])
  assert(!File.exist?(directory), 'Akceptacja nie nadaje capability tworzenia/rozpoczęcia')
end
puts 'REGRESJA PASS dwa odczyty, konflikt innego UUID i odmowa koordynacji bez portu'

windows = [
  {'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00'},
  {'date' => '2026-10-16', 'start' => '18:00', 'end_date' => '2026-10-17', 'end' => '01:00'}
]
with_fixture(windows: windows) do |f|
  b = f.backend
  record = b.accept(preview: b.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'wszystkie-okna'))
  assert_equal(2, record['evidence']['source']['windows'].size)
  record['evidence']['plan']['matches'].each do |match|
    match['windows'].each_with_index do |window, index|
      request = T::CoordinationRequest.from_execution_plan(evidence: record['evidence'], expected_source: record['expected_source'],
        match_id: match['match_id'], leg: match['leg'], window_id: window['id'], registry: GameRoomGames::CATALOG)
      assert_equal(window, request.to_h['window'])
      assert_equal(windows[index]['start'], Time.at(window['opens']).getlocal.strftime('%H:%M'))
      assert_equal(windows[index]['end_date'], Time.at(window['closes']).getlocal.strftime('%Y-%m-%d'))
    end
  end
end
# The machine running the suite may use UTC, with no repeated autumn hour.
# Keep the real resolver and backend; supply deterministic DST clock data.
[3600, 7200].each do |preferred|
  [['2026-10-25', :ambiguous_time], ['2026-03-29', :nonexistent_time]].each do |date, code|
    adapter = TournamentTimeSupport::SeasonalTime.new(preferred)
    TournamentTimeSupport.with_adapter(adapter) do
      with_fixture(windows: [{'date' => date, 'start' => '02:30', 'end_date' => date, 'end' => '05:00'}]) do |f|
        error = assert_raises(T::LocalRegistrationTime::Invalid) { f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'dst') }
        assert_equal(code, error.code)
        assert(!adapter.local_calls.empty?, 'The backend bypassed the real local-time resolver')
        assert(!File.exist?(File.join(f.directory,'k02','sandbox-k02.json')))
      end
    end
  end
end
puts 'PASS all windows, real system roundtrip, deterministic DST gap and fold rejection'

with_fixture do |f|
  armed = fired = false
  registry = Object.new
  registry.define_singleton_method(:build) do |id|
    if armed && !fired
      fired = true
      f.tables.fetch('tournament_registrations').insert(T::RegistrationProjection.join_values(tournament_id: 1, operation_key: SecureRandom.uuid))
    end
    GameRoomGames::CATALOG.build(id)
  end
  backend = f.backend(registry: registry)
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'zmiana-podczas-readback')
  trace = TracePoint.new(:call) { |event| armed = true if event.defined_class == T::LocalExecutionPlanBackend && event.method_id == :readback }
  begin
    trace.enable(target_thread: nil)
    error = assert_raises(T::Publication::Invalid) { backend.accept(preview: shown) }
    assert_equal(:source_changed, error.code, 'Nowa mutacja źródła podczas exact readback nie może zwrócić bieżącej zgody')
    assert(fired)
  ensure
    trace.disable
  end
  historic = f.backend.readback(intent_id: 'zmiana-podczas-readback')
  assert_equal(shown, historic['preview'], 'Zapisana intencja pozostaje historycznym dowodem')
end
puts 'PASS zmiana źródła podczas końcowego readback akceptacji'

with_fixture do |f|
  values = f.author_service.list['announcements'].first.slice(*T::Publication::COLUMNS)
  f.now = 150
  alias_row = f.tables.fetch('tournament_announcements').insert(values)
  f.actor = 'Gamma'
  f.tables.fetch('tournament_registrations').insert(T::RegistrationProjection.join_values(tournament_id: alias_row['__id'], operation_key: SecureRandom.uuid))
  f.actor, f.now = 'Organizator', 201
  source = f.author_service.execution_source(publication_ref: f.reference)
  assert_equal([1,2], source['projection']['announcements'].first['alias_ids'])
  assert_equal(%w[alpha beta gamma], source['candidate']['roster'])
  backend = f.backend
  record = backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'alias'))
  assert_equal(6, record['evidence']['plan']['matches'].size)
  assert_equal(%w[Alpha Beta Gamma], record['evidence']['source']['roster'].map { |p| p['username'] })
  assert_equal(T::ExecutionPlanContract.digest(record['evidence']['source']), record['expected_source']['source_digest'])
  assert_equal(source, record['preview']['source'])
  path = File.join(f.directory,'k02','sandbox-k02.json')
  original = File.binread(path)
  document = JSON.parse(original)
  document['version'] = 2
  File.binwrite(path, JSON.generate(document))
  error = assert_raises(T::Publication::Invalid) { backend.readback(intent_id: 'alias') }
  assert_equal(:sandbox_corrupt, error.code)
  File.binwrite(path, original)
  ( [nil, [], false, 'tekst'] ).each do |wrong|
    malformed = JSON.parse(original)
    malformed['records'][0]['preview']['source']['candidate'] = wrong
    File.binwrite(path, JSON.generate(malformed))
    error = assert_raises(T::Publication::Invalid) { backend.readback(intent_id: 'alias') }
    assert_equal(:sandbox_corrupt, error.code)
  end
  File.binwrite(path, original)
end
puts 'REGRESJA PASS membership z aliasu, odrębny digest A, ścisła wersja i błędne typy'

windows = (0...257).map do |index|
  date = (Date.new(2030,1,1) + index).strftime('%Y-%m-%d')
  {'date' => date, 'start' => '12:00', 'end_date' => date, 'end' => '21:00'}
end
with_fixture(windows: windows) do |f|
  candidate = f.author_service.schedule_candidate(publication_ref: f.reference).to_h
  assert_equal(257, candidate['windows'].size)
  error = assert_raises(T::Publication::Invalid) { f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: '257-okien') }
  assert_equal(:execution_plan_limit, error.code)
end
with_fixture(names: (1..16).map { |i| "Uczestnik#{i}" }, windows: windows.first(8)) do |f|
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'budzet-calego-A')
  assert_equal(240, shown['source']['candidate']['matches'].size, 'Liczność legalna, lecz cały A ma mniejszy budżet')
  error = assert_raises(T::Publication::Invalid) { backend.accept(preview: shown) }
  assert_equal(:json_budget, error.code)
  assert(!File.exist?(File.join(f.directory,'k02','sandbox-k02.json')), 'Bez częściowego planu po przekroczeniu bajtów/węzłów A')
end
puts 'REGRESJA PASS 257 okien i budżet całego A na rzeczywistym terminarzu 240 spotkań'
