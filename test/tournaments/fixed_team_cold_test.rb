# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
directory = File.join(ENV.fetch('FT1_SCRATCH'), 'shared', 'cold')
phase = Object.const_defined?(:FT1_COLD_PHASE) ? FT1_COLD_PHASE : 'A'
if phase == 'A'
  context, service, reference = fixture(directory: directory)
  source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
  with_backend(context) do |backend|
    shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'zimny-pierwszy')
    record = backend.accept(preview: shown)
    data = {'pid' => Process.pid, 'source' => source, 'record' => record, 'reference' => reference}
    File.open(File.join(directory, 'A.json'), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(data)) }
    oracle_file('oracle.json', data)
  end
else
  a = JSON.parse(File.read(File.join(directory, 'A.json'), encoding: 'UTF-8'))
  assert(a['pid'] != Process.pid)
  context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator')
  context.now = 201
  service, reference, source = context.service, a['reference'], a['source']
  with_backend(context) do |backend, _, _, _, plans|
    record = a['record']
    path = File.join(plans, 'fixed-teams-v1', 'sandbox-k02.json')
    bytes = File.binread(path)
    assert_equal(record, backend.readback(intent_id: 'zimny-pierwszy'))
    input = {publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source)}
    if phase == 'B'
      assert_equal(record, backend.current(intent_id: 'zimny-pierwszy'))
      assert_equal(record, backend.accept(preview: record['preview']))
      assert_equal(bytes, File.binread(path))
      shown = backend.preview(**input, intent_id: 'zimny-alias')
      assert_equal(record, backend.accept(preview: shown))
      bytes = File.binread(path)
      changed = membership
      changed['units'][0]['unit_id'] = 'nowa-ekipa'
      fresh = service.fixed_team_execution_source(publication_ref: reference, membership: changed, team_template: TEMPLATE)
      old = source['candidate']['matches'].select { |match| match['leg'] == 1 }
      base = fresh['candidate']['matches'].select { |match| match['leg'] == 1 }.to_h do |match|
        previous = old.find { |item| item['players'].sort == match['players'].sort }
        [match['match_id'], input[:base_seats].fetch(previous['match_id'])]
      end
      refused = backend.preview(**input.merge(membership: changed, base_seats: base), intent_id: 'zimny-konflikt')
      assert_equal(:source_conflict, assert_raises(T::Publication::Invalid) { backend.accept(preview: refused) }.code)
      assert_equal(bytes, File.binread(path))
      File.open(File.join(directory, 'B.json'), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate({'pid' => Process.pid, 'alias' => shown, 'refused' => refused, 'record' => record})) }
    else
      b = JSON.parse(File.read(File.join(directory, 'B.json'), encoding: 'UTF-8'))
      assert(b['pid'] != Process.pid)
      assert_equal(record, backend.readback(intent_id: 'zimny-alias'))
      assert_equal(record, backend.accept(preview: b['alias']))
      assert_equal(bytes, File.binread(path))
      context.actor, context.insert_time = 'Dorota', 150
      context.provider.insert_row(TournamentPublicServiceSupport::REG,
        T::RegistrationProjection.join_values(tournament_id: source['announcements'].first['__id'], operation_key: 'zimny-join'))
      context.actor = 'Organizator'
      assert(service.list['members'].any? { |person| person['account'] == 'dorota' })
      assert_equal(:invalid_membership, assert_raises(T::Publication::Invalid) { backend.current(intent_id: 'zimny-pierwszy') }.code)
      assert_equal(record, backend.readback(intent_id: 'zimny-pierwszy'))
      assert_equal(record, backend.readback(intent_id: 'zimny-alias'))
      assert_equal(bytes, File.binread(path))
    end
    oracle_file('oracle.json', {'phase' => phase, 'pid' => Process.pid, 'record' => record, 'document' => JSON.parse(File.binread(path))})
  end
end
puts "FT1: zimna faza #{phase}, wyłącznie pliki — OK"
