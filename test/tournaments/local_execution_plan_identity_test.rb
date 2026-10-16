# encoding: UTF-8
require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport

# Zmieniają się rzeczywiste dowody tabel, nie wykonawcze źródło pierwszego turnieju.
def change_observation(f, kind)
  case kind
  when :alias
    values = f.author_service.list['announcements'].first.slice(*T::Publication::COLUMNS)
    f.tables.fetch('tournament_announcements').insert(values)
  when :outside_window
    f.actor = 'Beta'
    f.tables.fetch('tournament_registrations').insert(T::RegistrationProjection.join_values(tournament_id: 1, operation_key: SecureRandom.uuid))
    f.actor = 'Organizator'
  when :unrelated
    f.now = 150
    operation = f.author_service.publish(**params('chess', draft: draft.merge('rematch' => true),
      intent_id: 'inna-publikacja', timezone: 'local_test:system'))
    assert_equal('confirmed', operation['status'])
    f.now = 201
  end
end

def identity_path(f)
  File.join(f.directory, 'k02', 'sandbox-k02.json')
end

def invalid_code(code)
  error = assert_raises(T::Publication::Invalid) { yield }
  assert_equal(code, error.code)
end

cases = {}
[:alias, :outside_window, :unrelated].product([:same, :reverse]).each do |change, seats|
  cases["#{change}/#{seats}"] = -> do
    with_fixture do |f|
      b = f.backend
      base = f.base
      initial = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'first')
      first = b.accept(preview: initial)
      before = File.binread(identity_path(f))
      change_observation(f, change)
      shown = b.preview(publication_ref: f.reference, base_seats: seats == :same ? base : base.transform_values(&:reverse), intent_id: 'next')
      assert_equal(initial['source']['candidate'], shown['source']['candidate'])
      assert(initial['source'] != shown['source'] && initial['digest'] != shown['digest'], 'Nowy pokazany snapshot ma własny digest')
      invalid_code(:source_changed) { b.current(intent_id: 'first') }
      if seats == :reverse
        invalid_code(:source_conflict) { b.accept(preview: shown) }
        assert_equal(before, File.binread(identity_path(f)), 'Konflikt nie zapisuje planu ani aliasu')
        assert_equal(nil, f.backend.readback(intent_id: 'next'))
      else
        assert_equal(first, b.accept(preview: shown), 'Nie wolno ponownie utworzyć ID ani generacji')
        document = JSON.parse(File.binread(identity_path(f)))
        assert_equal([first], document['records'], 'Pierwszy rekord niezmieniony')
        link = document['intents'].find { |row| row['intent_id'] == 'next' }
        assert_equal(shown['digest'], link['digest'])
        assert_equal(shown, link['preview'], 'Trwały dowód dokładnie zaakceptowanego nowego snapshotu')
        assert_equal('first', link['record_intent_id'])
        reopened = f.backend
        assert_equal(first, reopened.readback(intent_id: 'next'))
        bytes = File.binread(identity_path(f))
        assert_equal(first, reopened.accept(preview: shown))
        assert_equal(bytes, File.binread(identity_path(f)), 'Retry nie zapisuje')
        changed = reopened.preview(publication_ref: f.reference, base_seats: base.transform_values(&:reverse), intent_id: 'next')
        invalid_code(:intent_conflict) { reopened.accept(preview: changed) }
        reuse_original = reopened.preview(publication_ref: f.reference, base_seats: base, intent_id: 'first')
        invalid_code(:intent_conflict) { reopened.accept(preview: reuse_original) }
        assert_equal(bytes, File.binread(identity_path(f)))
        first['evidence']['plan']['matches'].each { |match| request(first, match) }
      end
    end
  end
end

[:same, :reverse].each do |seats|
  cases["history_duplicate/#{seats}"] = -> do
    with_fixture do |f|
      b = f.backend
      base = f.base
      one = b.accept(preview: b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'one'))
      path = identity_path(f)
      first_document = JSON.parse(File.binread(path))
      assert_equal(one, f.backend.readback(intent_id: 'one'), 'Pierwszy dokument osobno legalny')
      change_observation(f, :alias)
      # Dwa osobno legalne historyczne dokumenty tej SAMEJ tożsamości magazynu.
      File.delete(path)
      two = b.accept(preview: b.preview(publication_ref: f.reference, base_seats: seats == :same ? base : base.transform_values(&:reverse), intent_id: 'two'))
      second_document = JSON.parse(File.binread(path))
      assert_equal(two, f.backend.readback(intent_id: 'two'), 'Drugi dokument osobno legalny')
      assert_equal(one['evidence']['source'], two['evidence']['source'])
      assert_equal(one['expected_source'], two['expected_source'])
      assert_equal(one['evidence']['scope'], two['evidence']['scope'])
      assert(one['preview']['source'] != two['preview']['source'], 'Różne dane obserwacji')
      first_document['records'].concat(second_document['records'])
      first_document['intents'].concat(second_document['intents'])
      bytes = JSON.generate(first_document)
      File.binwrite(path, bytes)
      shown = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'three')
      [:read_one, :read_two, :read_absent, :accept].each do |action|
        invalid_code(:sandbox_corrupt) do
          case action
          when :accept then b.accept(preview: shown)
          when :read_one then b.readback(intent_id: 'one')
          when :read_two then b.readback(intent_id: 'two')
          else b.readback(intent_id: 'unselected')
          end
        end
        assert_equal(bytes.b, File.binread(path), 'Odmowa całego dokumentu przed claim/write/wynikiem')
      end
    end
  end
end

cases['alias_relations_and_legacy'] = -> do
  with_fixture do |f|
    b = f.backend
    base = f.base
    one = b.accept(preview: b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'one'))
    # Stare trzy pola v1 są legalne, jeśli odtwarzają rzeczywisty digest.
    legacy_preview = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'legacy')
    b.accept(preview: legacy_preview)
    path = identity_path(f)
    legacy = JSON.parse(File.binread(path))
    legacy['intents'].each { |link| link.delete('preview') }
    File.binwrite(path, JSON.generate(legacy))
    bytes = File.binread(path)
    assert_equal(one, f.backend.readback(intent_id: 'legacy'))
    assert_equal(bytes, File.binread(path), 'Odczyt v1 bez migracji')
    change_observation(f, :outside_window)
    shown = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'alias')
    assert_equal(one, b.accept(preview: shown))
    original = File.binread(path)
    reversed = b.preview(publication_ref: f.reference, base_seats: base.transform_values(&:reverse), intent_id: 'alias')
    # Również legalny preview innego źródła/turnieju nie potwierdza tego aliasu.
    change_observation(f, :unrelated)
    other_row = f.author_service.list['announcements'].last
    f.now = 150
    %w[Beta Alpha].each do |actor|
      f.actor = actor
      assert_equal('confirmed', f.service(f.journal_for(actor)).join(tournament_id: other_row['__id'])['status'])
    end
    f.actor, f.now = 'Organizator', 201
    ref = {'author' => 'Organizator', 'publication_key' => other_row['publication_key']}
    candidate = f.author_service.schedule_candidate(publication_ref: ref).to_h
    other_base = candidate['matches'].select { |m| m['leg'] == 1 }.to_h { |m| [m['match_id'], m['players'].reverse] }
    other_preview = b.preview(publication_ref: ref, base_seats: other_base, intent_id: 'alias')
    mutations = {
      'missing_proof' => ->(link) { link.delete('preview') },
      'old_digest' => ->(link) { link['digest'] = legacy_preview['digest'] },
      'changed_basis' => ->(link) { link['preview'] = reversed; link['digest'] = reversed['digest'] },
      'other_source' => ->(link) { link['preview'] = other_preview; link['digest'] = other_preview['digest'] },
      'forged_key' => ->(link) { link['execution_key'] = one['expected_source']['source_digest'] },
      'intent_mismatch' => ->(link) { link['preview']['intent_id'] = 'not-alias' }
    }
    mutations.each do |name, mutate|
      doc = JSON.parse(original)
      mutate.call(doc['intents'].find { |link| link['intent_id'] == 'alias' })
      corrupt = JSON.generate(doc)
      File.binwrite(path, corrupt)
      invalid_code(:sandbox_corrupt) { f.backend.readback(intent_id: 'one') }
      assert_equal(corrupt.b, File.binread(path), name)
    end
    File.binwrite(path, original)
    # Inny turniej to legalny drugi rekord, nie fałszywy konflikt.
    legal = b.preview(publication_ref: ref, base_seats: other_base, intent_id: 'other-tournament')
    second = b.accept(preview: legal)
    assert_equal(second, f.backend.readback(intent_id: 'other-tournament'))
    assert_equal(one, f.backend.readback(intent_id: 'alias'))
    assert_equal(2, JSON.parse(File.binread(path))['records'].size)
  end
end

results = cases.map do |name, run|
  begin
    run.call
    puts "PASS #{name}"
    {'case' => name, 'passed' => true}
  rescue StandardError => error
    puts "FAIL #{name}: #{error.class}: #{error.message}"
    {'case' => name, 'passed' => false, 'error' => error.message, 'backtrace' => error.backtrace}
  end
end
if ENV['ENTRY_EVIDENCE']
  File.binwrite(File.join(ENV['ENTRY_EVIDENCE'], 'identity-test.json'), JSON.pretty_generate(results))
end
raise 'Wyłączność/relacje tożsamości K02' unless results.all? { |row| row['passed'] }
