# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, build, _, _, directory|
  input = {publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source)}
  shown = backend.preview(**input, intent_id: 'pierwszy')
  record = backend.accept(preview: shown)
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  episodes = []
  # Alias ogłoszenia, legalny późny join i niezwiązane ogłoszenie nie zmieniają klucza.
  ann = source['announcements'].first.reject { |key, _| key.start_with?('__') }
  context.provider.insert_row(TournamentPublicServiceSupport::ANN, ann)
  registration = source['registrations'].first
  context.actor = registration['__insertion_user']
  context.provider.insert_row(TournamentPublicServiceSupport::REG, registration.reject { |key, _| key.start_with?('__') }.merge('operation_key' => 'pozne-potwierdzenie'))
  context.actor = 'Organizator'
  context.now = 150
  settings = draft('spades').merge('players_per_match' => 4, 'rematch' => true)
  settings['game_options'] = REGISTRY.build('spades').normalize_options('team_size' => 2)
  other = service.publish(**params('spades', draft: settings, timezone: 'local_test:system', intent_id: 'drugi-turniej'))
  assert_equal('confirmed', other['status'])
  context.now = 201
  alias_preview = backend.preview(**input, intent_id: 'alias-obserwacji')
  assert(!shown['source'].eql?(alias_preview['source']))
  assert_equal(record, backend.accept(preview: alias_preview))
  episodes << {'alias' => alias_preview, 'record' => record}
  before = File.binread(path)
  current_error = assert_raises(T::Publication::Invalid) { backend.current(intent_id: 'pierwszy') }
  assert_equal(:source_changed, current_error.code)
  assert_equal(record, backend.readback(intent_id: 'pierwszy'))
  [
    input.merge(base_seats: input[:base_seats].transform_values(&:reverse)),
    input.merge(team_template: [0, 0, 1, 1], base_seats: bases(service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: [0, 0, 1, 1]), [0, 0, 1, 1]))
  ].each_with_index do |changed, index|
    candidate = backend.preview(**changed, intent_id: "konflikt-#{index}")
    error = assert_raises(T::Publication::Invalid) { backend.accept(preview: candidate) }
    assert_equal(:source_conflict, error.code)
    assert_equal(before, File.binread(path))
    episodes << {'conflicting' => candidate, 'code' => error.code}
  end
  members = membership
  members['units'][0]['accounts'][1], members['units'][1]['accounts'][0] = members['units'][1]['accounts'][0], members['units'][0]['accounts'][1]
  changed_source = service.fixed_team_execution_source(publication_ref: reference, membership: members, team_template: TEMPLATE)
  units = changed_source['candidate']['membership']['units'].to_h { |unit| [unit['unit_id'], unit['accounts']] }
  base = changed_source['candidate']['matches'].select { |match| match['leg'] == 1 }.to_h do |match|
    x, y = match['unit_ids'].map { |id| units[id] }
    [match['match_id'], [x[0], y[0], x[1], y[1]]]
  end
  changed = backend.preview(**input.merge(membership: members, base_seats: base), intent_id: 'inne-ekipy')
  assert(changed['source']['candidate']['roster_digest'] != source['candidate']['roster_digest'])
  error = assert_raises(T::Publication::Invalid) { backend.accept(preview: changed) }
  assert_equal(:source_conflict, error.code)
  assert_equal(before, File.binread(path))
  # Drugi rzeczywiście legalny turniej w tym samym magazynie.
  second_ref = {'author' => 'Organizator', 'publication_key' => other['values']['publication_key']}
  other_id = service.list['announcements'].find { |row| row['publication_key'] == second_ref['publication_key'] }['__id']
  context.now = 150
  NAMES.each do |name|
    context.actor = name
    assert_equal('confirmed', context.service(journal: context.reopen_journal).join(tournament_id: other_id)['status'])
  end
  context.actor = 'Organizator'
  context.now = 201
  second_source = service.fixed_team_execution_source(publication_ref: second_ref, membership: membership, team_template: TEMPLATE)
  second_input = input.merge(publication_ref: second_ref, base_seats: bases(second_source))
  second_shown = backend.preview(**second_input, intent_id: 'drugi')
  second_record = backend.accept(preview: second_shown)
  legal = File.binread(path)
  corrupted = JSON.parse(legal)
  records_before = JSON.generate(corrupted['records'])
  alien_preview = backend.preview(**second_input, intent_id: 'pierwszy')
  link = corrupted['intents'].find { |item| item['intent_id'] == 'pierwszy' }
  link.merge!('record_intent_id' => 'drugi', 'preview' => alien_preview, 'digest' => alien_preview['digest'])
  assert_equal(records_before, JSON.generate(corrupted['records']))
  File.binwrite(path, JSON.generate(corrupted))
  corrupt_bytes = File.binread(path)
  rejected = %w[pierwszy drugi alias-obserwacji nieobecny].map do |id|
    error = assert_raises(T::Publication::Invalid) { build.call.readback(intent_id: id) }
    assert_equal(:sandbox_corrupt, error.code)
    [id, error.code]
  end
  fresh = backend.preview(**second_input, intent_id: 'nowy')
  assert_equal(:sandbox_corrupt, assert_raises(T::Publication::Invalid) { backend.accept(preview: fresh) }.code)
  assert_equal(corrupt_bytes, File.binread(path))
  File.binwrite(path, legal)
  # Rzeczywista późno widoczna osoba blokuje current, nie historyczny rekord.
  context.actor = 'Dorota'
  context.insert_time = 150
  context.provider.insert_row(TournamentPublicServiceSupport::REG,
    T::RegistrationProjection.join_values(tournament_id: source['announcements'].first['__id'], operation_key: 'nowa-osoba'))
  context.actor = 'Organizator'
  assert(service.list['members'].any? { |member| member['account'] == 'dorota' }, 'Zmiana rzeczywistego rosteru, nie diagnostyka wadliwego join')
  unchanged = File.binread(path)
  assert_raises(T::Publication::Invalid) { backend.current(intent_id: 'pierwszy') }
  assert_equal(record, backend.readback(intent_id: 'pierwszy'))
  assert_equal(unchanged, File.binread(path))
  oracle_file('oracle.json', {'episodes' => episodes, 'changed_membership' => changed, 'second_record' => second_record,
    'legal' => JSON.parse(legal), 'corrupted' => corrupted, 'relink_rejections' => rejected, 'current_rejection' => current_error.code})
end
puts 'FT1: wyłączność bez snapshotu i globalna rezerwacja pierwotnych ID — OK'
