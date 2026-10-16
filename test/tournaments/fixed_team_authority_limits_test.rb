# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, _, _, _, directory|
  args = {directory: directory, tables: context.provider, journal: context.journal, actor: 'Organizator', registry: REGISTRY, clock: -> { context.now }}
  assert_equal(:invalid_composition, assert_raises(T::Publication::Invalid) { T::LocalFixedTeamPlanBackend.new(**args, context: {'account' => 'organizator'}) }.code)
  reader = T::LocalFixedTeamPlanBackend.new(**args)
  input = {publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'autorytet'}
  shown = reader.preview(**input)
  assert_equal(:context_unavailable, assert_raises(T::Publication::Invalid) { reader.accept(preview: shown) }.code)
  record = backend.accept(preview: shown)
  assert_equal(record, reader.readback(intent_id: 'autorytet'))
  assert_equal(:context_unavailable, assert_raises(T::Publication::Invalid) { reader.current(intent_id: 'autorytet') }.code)
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  bytes = File.binread(path)
  checks = []
  {'records' => 9, 'intents' => 4097}.each do |field, size|
    document = JSON.parse(bytes)
    document[field] = Array.new(size) { document[field][0] }
    File.binwrite(path, JSON.generate(document))
    before = File.binread(path)
    error = assert_raises(T::Publication::Invalid) { reader.readback(intent_id: 'autorytet') }
    assert_equal(:sandbox_limit, error.code)
    assert_equal(before, File.binread(path))
    checks << {'field' => field, 'count' => size, 'code' => error.code}
  end
  File.binwrite(path, ' ' * (T::LocalExecutionPlanStorage::MAX_BYTES + 1))
  assert_equal(:sandbox_limit, assert_raises(T::Publication::Invalid) { reader.readback(intent_id: 'autorytet') }.code)
  File.binwrite(path, bytes)
  assert_equal(record, reader.readback(intent_id: 'autorytet'))
  a = T::ExecutionPlanContract
  mutated = a.copy(record['evidence'])
  mutated['plan']['id'] = 'x' * 262_145
  assert_equal(:json_budget, assert_raises(T::Publication::Invalid) { a.validate(mutated, record['expected_source'], registry: REGISTRY) }.code)
  match = record['evidence']['plan']['matches'][0]
  assert_equal(:json_budget, assert_raises(T::Publication::Invalid) do
    T::FixedTeamSeats.native(game: REGISTRY.build('spades'), options: match['options'].merge('nadmiar' => 'x' * (T::Publication::MAX_JSON_BYTES + 1)),
      people: match['players'], template: TEMPLATE)
  end.code)
  oracle_file('oracle.json', {'record' => record, 'storage_limits' => checks, 'hash_not_authority' => true, 'no_context_accept' => :context_unavailable})
end
puts 'FT1: brak autorytetu Hash/nil, limity całego A/native/magazynu — OK'
