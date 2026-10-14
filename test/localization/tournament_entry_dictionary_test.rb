# encoding: UTF-8
require_relative '../../tools/support/translation_catalog'
require_relative '../../tools/support/translation_extractor'
require_relative '../../lib/game_room_localization'

class TournamentDictionaryAssertion < StandardError; end
def verify(value, message)
  raise TournamentDictionaryAssertion, message unless value
end

expected = {
  'Check status' => 'Sprawdź stan',
  'Checking original match coordination' => 'Sprawdzanie pierwotnej koordynacji spotkania',
  'Declare readiness' => 'Zadeklaruj gotowość',
  'Game: %{game}' => 'Gra: %{game}',
  'Match %{number}, leg %{leg}: %{players}' => 'Spotkanie %{number}, rozegranie %{leg}: %{players}',
  'Match ID: %{id}' => 'Identyfikator spotkania: %{id}',
  'Match details' => 'Szczegóły spotkania',
  'My matches' => 'Moje spotkania',
  'My matches — readiness and coordination' => 'Moje spotkania — gotowość i koordynacja',
  'My tournaments' => 'Moje turnieje',
  'No confirmed registration for this test participant. Viewing does not join a tournament.' => 'Brak potwierdzonego zapisu tego testowego uczestnika. Przeglądanie nie zapisuje do turnieju.',
  'Options: %{options}' => 'Ustawienia: %{options}',
  'Propose playing now' => 'Zaproponuj rozegranie teraz',
  'Readiness and coordination' => 'Gotowość i koordynacja',
  'Readiness is not confirmed. This candidate is not a final plan. Roles are unassigned. Readiness writes and match coordination are unavailable; no match can be started.' => 'Gotowość nie jest potwierdzona. Ten wstępny plan spotkań nie jest ostateczny. Role nie są przydzielone. Zapisywanie gotowości i koordynacja spotkań są niedostępne; nie można rozpocząć żadnego spotkania.',
  'Reading a local test schedule candidate' => 'Odczytywanie wstępnego planu spotkań w lokalnym teście',
  'Registration is still open. A schedule candidate cannot be calculated yet.' => 'Zapisy nadal trwają. Nie można jeszcze wyznaczyć wstępnego planu spotkań.',
  'The confirmed roster exceeds the schedule candidate limit.' => 'Liczba potwierdzonych uczestników przekracza limit wyznaczania wstępnego planu spotkań.',
  'The original coordination operation cannot be confirmed in this context. No new operation was sent.' => 'W tym kontekście nie można potwierdzić pierwotnej operacji koordynacji. Nie wysłano nowej operacji.',
  'The original coordination operation is pending. Check again without sending a new operation.' => 'Pierwotna operacja koordynacji oczekuje na rozstrzygnięcie. Sprawdź ponownie bez wysyłania nowej operacji.',
  'The original coordination result is unknown. Check again without sending a new operation.' => 'Wynik pierwotnej operacji koordynacji jest nieznany. Sprawdź ponownie bez wysyłania nowej operacji.',
  'The original match binding is confirmed. This does not authorize starting the match.' => 'Pierwotne powiązanie spotkania jest potwierdzone. Nie daje to uprawnienia do rozpoczęcia spotkania.',
  'The original reservation is confirmed. No table creation or start was requested.' => 'Pierwotna rezerwacja jest potwierdzona. Nie zażądano utworzenia stołu ani rozpoczęcia gry.',
  'The publication is no longer confirmed. The last valid view is retained.' => 'Publikacja nie jest już potwierdzona. Zachowano ostatni poprawny widok.',
  'The registration source contains unresolved conflicts. The last valid view is retained.' => 'Źródło zapisów zawiera nierozstrzygnięte konflikty. Zachowano ostatni poprawny widok.',
  'The status could not be read completely. The last valid view is retained.' => 'Nie udało się odczytać pełnego stanu. Zachowano ostatni poprawny widok.',
  'There are too few confirmed participants for a complete match.' => 'Brakuje potwierdzonych uczestników do pełnego składu spotkania.',
  'This is an observed candidate, not a final plan.' => 'To wstępny plan spotkań wyznaczony na podstawie odczytanych danych, a nie plan ostateczny.',
  'This tournament format does not support a schedule candidate.' => 'Dla tego systemu turnieju nie można wyznaczyć wstępnego planu spotkań.',
  'Use Check status to read your confirmed registrations. No readiness or coordination will be sent.' => 'Użyj przycisku „Sprawdź stan”, aby odczytać swoje potwierdzone zapisy. Nie zostanie wysłana deklaracja gotowości ani operacja koordynacji.',
  'View details' => 'Pokaż szczegóły',
  'Windows: %{windows}' => 'Okna rozgrywek: %{windows}'
}.freeze
root = File.expand_path('../..', __dir__)
mo_path = ARGV[0] || File.join(root, 'locale/PL.mo')
verify(File.file?(mo_path), "Brak compiled MO: #{mo_path}")
raw = GetText::MO.open(mo_path).to_h.transform_keys(&:b).transform_values(&:b)
catalog = GameRoomLocalization::Catalog.new(File.binread(mo_path))
translator = GameRoomLocalization::Translator.new(catalogs: {'pl' => catalog}, primary: 'pl', known: ['pl'])
english = GameRoomLocalization::Translator.new(catalogs: {}, primary: 'en', known: ['en'])
records = %w[entry_context local_test_hub local_workspace match_entry match_entry_screen public_service].flat_map do |name|
  path = "lib/tournaments/#{name}.rb"
  GameRoomTranslationExtractor.extract_source(File.binread(File.join(root, path)), path: path, warnings: [])
end
expected.each do |source, polish|
  verify(records.any? { |r| r[:msgid] == source }, "Brak msgid w binarnych źródłach: #{source}")
  verify(raw.key?(source.b), "Brak nowego PL w compiled MO: #{source}")
  actual = translator.translate(source.b)
  verify(actual.scan(/%\{[^}]+\}/).sort == source.scan(/%\{[^}]+\}/).sort, "Niezgodny parametr MO: #{source}")
  verify(actual == polish && raw.fetch(source.b) == polish.b, "Błędne tłumaczenie: #{source}: #{actual.inspect}")
  verify(actual.encoding == Encoding::UTF_8 && actual.valid_encoding?, "Błędne UTF-8: #{source}")
  verify(english.translate(source.b) == source, "Błędny fallback EN: #{source}")
  parameters = source.scan(/%\{([^}]+)\}/).flatten.to_h { |key| [key.to_sym, "Żółć-#{key}"] }
  verify((actual % parameters).valid_encoding?, "Uszkodzona interpolacja: #{source}") unless parameters.empty?
end
puts "PASS: #{expected.length} nowych komunikatów PL z compiled MO i EN z binarnych źródeł; pełne wartości i parametry"
