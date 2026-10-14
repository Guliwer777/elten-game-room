# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, build, _, _, directory|
  shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'pierwszy')
  record = backend.accept(preview: shown)
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  bytes = File.binread(path)
  a = T::ExecutionPlanContract
  evidence, anchor = record.values_at('evidence', 'expected_source')
  # Zmiana jednej nogi dochodzi do relacji rewanżu, mimo poprawnego digestu.
  single = a.copy(evidence)
  match = single['plan']['matches'][0]
  match['players'] = match['players'].values_at(1, 0, 3, 2).each_with_index.map { |person, seat| person.merge('seat' => seat, 'game_role' => "seat:#{seat}") }
  single['plan_digest'] = a.digest(single.slice('scope', 'plan'))
  error = assert_raises(T::Publication::Invalid) { a.validate(single, anchor, registry: REGISTRY) }
  assert_equal(:niezgodna_obsada, error.code)
  both = a.copy(single)
  match = both['plan']['matches'][3]
  match['players'] = match['players'].values_at(1, 0, 3, 2).each_with_index.map { |person, seat| person.merge('seat' => seat, 'game_role' => "seat:#{seat}") }
  both['plan_digest'] = a.digest(both.slice('scope', 'plan'))
  assert_equal(both, a.validate(both, anchor, registry: REGISTRY), 'Neutralne A nie udaje podpisu historycznego base')
  corrupted = JSON.parse(bytes)
  corrupted['records'][0]['evidence'] = both
  %w[request_digests native_payload_digests].each do |key|
    factory = key == 'request_digests' ? T::CoordinationRequest : T::FixedTeamNativePayload
    corrupted['records'][0][key] = both['plan']['matches'].to_h do |item|
      [item['match_id'], item['windows'].to_h do |window|
        result = factory.from_execution_plan(evidence: both, expected_source: anchor, match_id: item['match_id'], leg: item['leg'], window_id: window['id'], registry: REGISTRY)
        [window['id'], result.digest]
      end]
    end
  end
  assert_equal(shown, corrupted['records'][0]['preview'])
  File.binwrite(path, JSON.generate(corrupted))
  changed_bytes = File.binread(path)
  refusals = %w[pierwszy nieobecny].map do |id|
    rejected = assert_raises(T::Publication::Invalid) { build.call.readback(intent_id: id) }
    assert_equal(:sandbox_corrupt, rejected.code)
    rejected.code
  end
  rejected = assert_raises(T::Publication::Invalid) { backend.accept(preview: shown) }
  assert_equal(:sandbox_corrupt, rejected.code)
  assert_equal(changed_bytes, File.binread(path))
  File.binwrite(path, bytes)
  mutations = {
    'unit_id' => ->(data) { data['source']['matches'][0]['unit_ids'][0] = 'unit-X' },
    'czlonek' => ->(data) { data['plan']['matches'][-1]['players'][0]['team'] = 'unit-A' },
    'leg' => ->(data) { data['plan']['matches'][-1]['leg'] = 1 },
    'template' => ->(data) { data['source']['team_template'] = [0, 0, 1, 1] },
    'options' => ->(data) { data['plan']['matches'][-1]['options']['score_limit'] += 1 },
    'native_public' => ->(data) { data['plan']['matches'][-1]['options']['team_players'] = NAMES.first(4) },
    'v1_plus_v2' => ->(data) { data['version'] = 1 }
  }
  negative = mutations.to_h do |name, change|
    value = a.copy(evidence)
    change.call(value)
    value['plan_digest'] = a.digest(value.slice('scope', 'plan'))
    error = assert_raises(T::Publication::Invalid) do
      T::FixedTeamNativePayload.from_execution_plan(evidence: value, expected_source: anchor,
        match_id: evidence['plan']['matches'][0]['match_id'], leg: 1, window_id: evidence['source']['windows'][0]['id'], registry: REGISTRY)
    end
    [name, {'data' => value, 'code' => error.code}]
  end
  # Callback prawdziwego katalogu mutuje wyłącznie wejścia wywołującego.
  first = evidence['plan']['matches'][0]
  expected = T::FixedTeamNativePayload.from_execution_plan(evidence: evidence, expected_source: anchor, match_id: first['match_id'], leg: 1,
    window_id: first['windows'][0]['id'], registry: REGISTRY)
  match_id, window_id = first['match_id'].dup, first['windows'][0]['id'].dup
  mutable = a.copy(evidence)
  calls = 0
  registry = Object.new
  registry.define_singleton_method(:build) do |id|
    calls += 1
    if calls == 1
      worker = Thread.new do
        match_id.replace(evidence['plan']['matches'][1]['match_id'])
        window_id.replace(first['windows'][1]['id'])
        mutable['plan']['matches'].clear
      end
      worker.value
    end
    REGISTRY.build(id)
  end
  actual = T::FixedTeamNativePayload.from_execution_plan(evidence: mutable, expected_source: anchor, match_id: match_id, leg: 1,
    window_id: window_id, registry: registry)
  assert_equal(expected.to_h, actual.to_h)
  assert_equal(expected.digest, actual.digest)
  assert(!match_id.frozen? && !window_id.frozen?, 'Caller nie jest zamrażany')
  # Wspólny String dwóch selektorów jest legalny w neutralnym źródle okien.
  shared_data = a.copy(evidence)
  old_window = first['windows'][0]['id']
  shared_data['source']['windows'][0]['id'] = first['match_id']
  shared_data['source']['matches'].each { |item| item['window_ids'][0] = first['match_id'] }
  shared_data['plan']['matches'].each { |item| item['windows'][0]['id'] = first['match_id'] }
  shared_anchor = shared_data['source'].slice(*a::ANCHOR).merge('source_digest' => a.digest(shared_data['source']))
  shared_data['seal']['source_digest'] = shared_data['plan']['source_digest'] = shared_anchor['source_digest']
  shared_data['plan_digest'] = a.digest(shared_data.slice('scope', 'plan'))
  selector = first['match_id'].dup
  shared_expected = T::FixedTeamNativePayload.from_execution_plan(evidence: shared_data, expected_source: shared_anchor,
    match_id: selector, leg: 1, window_id: selector, registry: REGISTRY)
  once = false
  registry.define_singleton_method(:build) do |id|
    unless once
      once = true
      selector.replace('zmieniono-wspolny-string')
    end
    REGISTRY.build(id)
  end
  shared_actual = T::FixedTeamNativePayload.from_execution_plan(evidence: shared_data, expected_source: shared_anchor,
    match_id: selector, leg: 1, window_id: selector, registry: registry)
  assert_equal(shared_expected.to_h, shared_actual.to_h)
  oracle_file('oracle.json', {'record' => record, 'single_leg' => single, 'single_rejection' => :niezgodna_obsada,
    'both_legs' => both, 'backend_refusals' => refusals, 'corrupted' => corrupted, 'negative' => negative,
    'mutation_expected' => expected.to_h, 'mutation_actual' => actual.to_h, 'shared_expected' => shared_expected.to_h, 'shared_actual' => shared_actual.to_h})
end
puts 'FT1: pełne A, dwie różne granice obsady i odłączenie selektorów — OK'
