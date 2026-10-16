# encoding: UTF-8
# Weryfikacja istniejącego zachowania, nie historyczny RED nowej funkcji.
# Dzieci nie dzielą runtime ani obiektów: wyłącznie izolowane pliki w TMPDIR.
require_relative '../support/tournament_restart_process'
include GameRoomTest::Assertions
R = TournamentRestartProcess
assert(!defined?(TournamentNativeDriver) && !defined?(GameRoomTournaments), 'Sam require pomocnika uruchomił bootstrap hosta')

module TournamentRestartAssertions
  extend GameRoomTest::Assertions
  module_function

  def table_counts(report, publications:, joins:)
    tables = R.subset(report.fetch('after'), /\/tournament-local-test-tables\.json\z/)
    assert(tables.one?, 'Oczekiwano jednego pliku tabel')
    bytes = Base64.strict_decode64(tables.values.first.fetch('base64'))
    states = JSON.parse(bytes).fetch('tables')
    {'tournament_announcements' => publications, 'tournament_registrations' => joins}.each do |name, count|
      state = states.fetch(name)
      assert(state.fetch('rows').length == count && state.fetch('last_id') == count, "Duplikat albo brak w tabeli #{name}")
    end
    expected_authors = {'tournament_announcements' => [R::ACTOR_A], 'tournament_registrations' => [R::ACTOR_A, R::ACTOR_B].first(joins)}
    states.each do |name, state|
      assert(state.fetch('rows').map { |row| row.fetch('__insertion_user') } == expected_authors.fetch(name), 'Właściciel plików udaje testowego aktora')
    end
  end

  def unchanged_draft(before, after)
    original = R.subset(before, /\Atournament-drafts-.*\.json\z/)
    assert(original.one?, 'Brak źródłowego pliku szkicu')
    assert(R.subset(after, /\Atournament-drafts-.*\.json\z/) == original, 'Zmieniono bajty szkicu/rosteru')
  end

  def registration_timing(report, origin:)
    bounds = origin.fetch('publish_button')
    assert(bounds.fetch('before') > origin.fetch('editor_observed_at') && bounds.fetch('after') >= bounds.fetch('before'), 'Nie zaobserwowano świeżego czasu przycisku po otwarciu edytora')
    assert(origin.fetch('registration_dates').keys == ['closes'], 'Raport udaje ręczne wpisanie automatycznego otwarcia')
    publication = report.fetch('snapshot').fetch('announcements').fetch(0)
    opens, closes = publication.values_at('registration_opens_at', 'registration_closes_at')
    assert(Integer === opens && opens.between?(bounds.fetch('before'), bounds.fetch('after')), 'UTC otwarcia poza granicami wywołania Publish')
    assert(closes == origin.fetch('registration_dates').fetch('closes').fetch('timestamp') && closes > opens, 'UTC końca nie odpowiada wybranemu terminowi')
  end

  def publication_operation(report, status:)
    operations = report.fetch('operations').select { |row| row['kind'] == 'publication' }
    assert(operations.one?, 'Brak pojedynczej operacji publikacji')
    operation = operations.first
    row = report.fetch('draft_rows').fetch(0)
    assert(operation.fetch('kind') == 'publication' && operation.fetch('status') == status &&
      operation.fetch('intent_id') == "draft:#{row.fetch('id')}:revision:#{row.fetch('revision')}", 'Błędny status lub revision intent')
    operation
  end
end
A = TournamentRestartAssertions
reports = []
root = nil
Dir.mktmpdir('tournament-local-restart-', R.temporary_base) do |directory|
  root = R.safe_path(directory)
  logs = R.safe_path(File.join(root, 'reports'))
  FileUtils.mkdir_p(logs)
  %w[normal uncertain].each do |scenario|
    data = R.safe_path(File.join(root, scenario))
    FileUtils.mkdir_p(data)
    phases = scenario == 'normal' ? %w[publish join return] : %w[uncertain_publish reconcile other_owner]
    group = phases.map do |phase|
      report = R.run_child(phase, data, logs)
      if reports.any?
        assert(report.fetch('lifecycle').fetch('started_monotonic') >= reports.last.fetch('lifecycle').fetch('reaped_monotonic'), 'Następny proces wystartował przed wait poprzednika')
      end
      assert(!reports.any? { |previous| previous.fetch('pid') == report.fetch('pid') }, 'System ponownie użył PID; ta próba nie dowodzi różnych PID')
      reports << report
      report
    end
    first, second, third = group
    assert(first.fetch('before').empty?, 'Fixture nie zaczyna się od pustego katalogu')
    assert(first.fetch('inserts').length == (scenario == 'normal' ? 2 : 1), 'Publication and confirmed organizer enrollment have the wrong write count')
    group.reject { |report| report.fetch('phase') == 'other_owner' }.each { |report| A.registration_timing(report, origin: first) }
    group.each { |report| A.unchanged_draft(first.fetch('draft_prepared'), report.fetch('after')) }
    group.each_cons(2) { |before, after| assert(before.fetch('after') == after.fetch('before'), 'Procesy nie czytają tych samych bajtów na dysku') }
    initial_operation = A.publication_operation(first, status: scenario == 'normal' ? 'confirmed' : 'attempted')
    assert(first.fetch('draft_rows').first.fetch('participants') == ['Lokalny roster A', 'Lokalny roster B'], 'Fixture straciło ręczny roster')
    if scenario == 'normal'
      A.table_counts(first, publications: 1, joins: 1)
      A.table_counts(second, publications: 1, joins: 2)
      A.table_counts(third, publications: 1, joins: 2)
      assert(second.fetch('inserts').length == 1 && third.fetch('inserts').empty?, 'Join lub ponowne Publish powielono')
      assert(second.fetch('operations').one? && second.fetch('operations').first.fetch('kind') == 'join' &&
        second.fetch('operations').first.fetch('status') == 'confirmed', 'Aktor B nie ma własnej potwierdzonej operacji Join')
      assert(A.publication_operation(third, status: 'confirmed') == initial_operation, 'Nowy proces A nie odczytał pierwotnej operacji')
      assert(third.fetch('after') == second.fetch('after'), 'Powrót A zmienił pliki lub ponowił insert')
      assert(third.fetch('forms').include?(R::OPERATIONS) && !third.fetch('forms').include?(R::EDITOR), 'Ta sama rewizja nie prowadzi wyłącznie do Operations')
      assert(third.fetch('messages').any? { |message| message.include?('already exists') }, 'Brak komunikatu o istniejącej operacji')
      R.verify_snapshot(third.fetch('snapshot'), joined: true)
    else
      A.table_counts(first, publications: 1, joins: 0)
      A.table_counts(second, publications: 1, joins: 1)
      before_check = second.fetch('before_check')
      assert(before_check.fetch('files') == first.fetch('after') && before_check.fetch('operations') == [initial_operation], 'Reopen wykonał automatyczne retry lub reconcile')
      confirmed = A.publication_operation(second, status: 'confirmed')
      assert(confirmed.fetch('id') == initial_operation.fetch('id'), 'Check zmienił operation ID')
      writes = second.fetch('inserts')
      assert(writes.one? && writes.first.fetch('table') == 'tournament_registrations' &&
        !second.fetch('forms').include?(R::EDITOR), 'Reconciliation may enroll the organizer once, never republish the announcement')
      assert(third.fetch('snapshot').fetch('announcements').empty? && third.fetch('snapshot').fetch('members').empty? &&
        third.fetch('operations').empty? && third.fetch('draft_rows').empty? && third.fetch('inserts').empty?, 'Przeciek do innego właściciela')
      second.fetch('after').each { |name, bytes| assert(third.fetch('after').fetch(name) == bytes, 'Inne konto zmieniło pierwotne pliki') }
    end
  end
end
assert(!Dir.exist?(root), 'Nie usunięto własnego katalogu TMPDIR')
puts 'PASS fresh Ruby: publikacja A, odrębny B/Join, powrót A/Operations; niepewny append i jawne Check; inny owner izolowany'
puts 'RESTART_LIFECYCLE ' + JSON.generate({'pids' => reports.map { |report| report.fetch('pid') }, 'cleanup' => true,
  'scope' => 'lokalne procesy Ruby; bez restartu klienta ELTEN, sieci, GUI lub urządzeń'})
