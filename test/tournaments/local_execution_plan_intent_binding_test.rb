# encoding: UTF-8
require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport

# Rzeczywiste dwa źródła, bez podmiany planera ani walidatora.
def binding_sources(f)
  b = f.backend
  first = b.accept(preview: b.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'first'))
  f.now = 150
  operation = f.author_service.publish(**params('chess', draft: draft.merge('rematch' => true),
    intent_id: 'independent-publication', timezone: 'local_test:system'))
  assert_equal('confirmed', operation['status'])
  row = f.author_service.list['announcements'].last
  %w[Beta Alpha].each do |actor|
    f.actor = actor
    assert_equal('confirmed', f.service(f.journal_for(actor)).join(tournament_id: row['__id'])['status'])
  end
  f.actor, f.now = 'Organizator', 201
  ref = {'author' => 'Organizator', 'publication_key' => row['publication_key']}
  candidate = f.author_service.schedule_candidate(publication_ref: ref).to_h
  base = candidate['matches'].select { |m| m['leg'] == 1 }.to_h { |m| [m['match_id'], m['players'].reverse] }
  second = b.accept(preview: b.preview(publication_ref: ref, base_seats: base, intent_id: 'second'))
  assert_equal(first, f.backend.readback(intent_id: 'first'))
  assert_equal(second, f.backend.readback(intent_id: 'second'))
  assert(first['evidence']['source'] != second['evidence']['source'])
  assert(first['evidence']['scope'] != second['evidence']['scope'])
  [first, second, ref, base, row]
end

def binding_bytes(f)
  Dir.glob(File.join(f.directory, '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
end

def binding_code(expected)
  error = assert_raises(T::Publication::Invalid) { yield }
  assert_equal(expected, error.code)
end

# Obserwator widzi rzeczywistą metodę storage; dodatnia kontrola poniżej.
def binding_writes
  calls = []
  path = File.expand_path('../../lib/tournaments/local_execution_plan_storage.rb', __dir__)
  trace = TracePoint.new(:call) do |event|
    if event.defined_class == T::LocalExecutionPlanStorage && event.method_id == :write && File.expand_path(event.path) == path
      calls << event.method_id
    end
  end
  begin
    trace.enable(target_thread: nil)
    yield
  ensure
    trace.disable
  end
  calls
end

cases = {}
cases['legal_two_records_legacy_and_proof_aliases'] = -> do
  with_fixture do |f|
    first, second, ref, base, row = binding_sources(f)
    legacy = f.backend.preview(publication_ref: ref, base_seats: base, intent_id: 'legacy')
    writes = binding_writes { assert_equal(second, f.backend.accept(preview: legacy)) }
    assert_equal([:write], writes, 'Dodatnia kontrola obserwatora zapisu')
    path = File.join(f.directory, 'k02', 'sandbox-k02.json')
    document = JSON.parse(File.binread(path))
    assert_equal(%w[digest intent_id record_intent_id], document['intents'].last.keys.sort)
    f.tables.fetch('tournament_announcements').insert(row.slice(*T::Publication::COLUMNS))
    shown = f.backend.preview(publication_ref: ref, base_seats: base, intent_id: 'proof-alias')
    assert_equal(second, f.backend.accept(preview: shown))
    document = JSON.parse(File.binread(path))
    assert_equal([first, second], document['records'], 'IDs, generacje, źródła i obsada pozostają dokładne')
    assert_equal(shown, document['intents'].last['preview'])
    assert_equal('second', document['intents'].last['record_intent_id'])
    original = binding_bytes(f)
    reopened = f.backend
    %w[first second legacy proof-alias].each do |id|
      assert_equal(id == 'first' ? first : second, reopened.readback(intent_id: id))
    end
    assert_equal(nil, reopened.readback(intent_id: 'absent'))
    assert_equal(second, reopened.accept(preview: shown), 'Exact retry po ponownym otwarciu')
    changed = reopened.preview(publication_ref: ref, base_seats: base.transform_values(&:reverse), intent_id: 'proof-alias')
    binding_code(:intent_conflict) { reopened.accept(preview: changed) }
    assert_equal(original, binding_bytes(f), 'Odczyt, retry i konflikt nie zapisują')
    [first, second].each { |r| r['evidence']['plan']['matches'].each { |m| request(r, m) } }
  end
end

cases['original_proof_observed_at_is_not_semantic_change'] = -> do
  with_fixture do |f|
    shown = f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'first')
    first = f.backend.accept(preview: shown)
    f.now += 1
    later = f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'first')
    assert(shown['source']['candidate']['observed_at'] != later['source']['candidate']['observed_at'])
    assert_equal(shown['digest'], later['digest'])
    path = File.join(f.directory, 'k02', 'sandbox-k02.json')
    document = JSON.parse(File.binread(path))
    document['intents'].first['preview'] = later
    File.binwrite(path, JSON.generate(document))
    bytes = binding_bytes(f)
    assert_equal(first, f.backend.readback(intent_id: 'first'))
    assert_equal(first, f.backend.accept(preview: later))
    assert_equal(bytes, binding_bytes(f), 'Brak migracji legalnego dowodu różniącego się observed_at')
  end
end

# Cztery ograniczone warianty jednego naruszenia: oba kierunki i oba schematy linku.
%w[first second].product([:proof, :legacy]).each do |reserved, form|
  cases["reserved_#{reserved}/#{form}"] = -> do
    with_fixture do |f|
      first, second, ref, base, row = binding_sources(f)
      target = reserved == 'first' ? second : first
      target_ref = reserved == 'first' ? ref : f.reference
      target_base = reserved == 'first' ? base : f.base
      if form == :legacy
        if reserved == 'first'
          proof = f.backend.preview(publication_ref: ref, base_seats: base, intent_id: reserved)
        else
          # Pierwszy dowód sprzed publikacji B; tylko intent i jego kanoniczny digest.
          proof = JSON.parse(JSON.generate(first['preview']))
          proof['intent_id'] = reserved
          semantic = JSON.parse(JSON.generate(proof))
          semantic.delete('digest')
          semantic['source']['candidate'].delete('observed_at')
          proof['digest'] = T::ExecutionPlanContract.digest(semantic)
        end
      else
        # Dokładna nowa gałąź z oryginalnego RR1: alias B zmienia snapshot, nie źródło wykonawcze.
        f.tables.fetch('tournament_announcements').insert(row.slice(*T::Publication::COLUMNS))
        proof = f.backend.preview(publication_ref: target_ref, base_seats: target_base, intent_id: reserved)
        assert(target['preview']['source'] != proof['source'])
        assert_equal(target['preview']['source']['candidate'], proof['source']['candidate'])
      end
      # Nowy WŁAŚCIWY podgląd jest świeży i przechodzi prawdziwy accept przed mutacją.
      fresh = f.backend.preview(publication_ref: ref, base_seats: base, intent_id: 'new-valid')
      path = File.join(f.directory, 'k02', 'sandbox-k02.json')
      legal = File.binread(path)
      assert_equal(second, f.backend.accept(preview: fresh))
      File.binwrite(path, legal)
      document = JSON.parse(legal)
      link = document['intents'].find { |item| item['intent_id'] == reserved }
      link.merge!('record_intent_id' => target['preview']['intent_id'], 'digest' => proof['digest'])
      link['preview'] = proof if form == :proof
      assert_equal([first, second], document['records'], 'Tylko intents są mutowane')
      File.binwrite(path, JSON.generate(document))
      bytes = binding_bytes(f)
      outcomes = []
      writes = binding_writes do
        %w[first second absent accept].each do |action|
          result = error = nil
          begin
            result = action == 'accept' ? f.backend.accept(preview: fresh) : f.backend.readback(intent_id: action)
          rescue T::Publication::Invalid => caught
            error = caught
          end
          outcomes << {'action' => action, 'code' => error&.code, 'nil_result' => result.nil?,
            'unchanged' => bytes == binding_bytes(f)}
        end
      end
      assert_equal([], writes, "Walidacja PRZED write: #{outcomes.inspect}")
      assert(outcomes.all? { |r| r['code'] == :sandbox_corrupt && r['nil_result'] && r['unchanged'] },
        "Każdy odczyt i nowy accept odmawia całego dokumentu: #{outcomes.inspect}")
    end
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
  File.binwrite(File.join(ENV['ENTRY_EVIDENCE'], 'intent-binding-test.json'), JSON.pretty_generate(results))
end
raise 'Pierwotny intent musi należeć do własnego rekordu i dowodu' unless results.all? { |row| row['passed'] }
