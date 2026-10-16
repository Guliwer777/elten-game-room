# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, service, first = fixture(directory: File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
references = [first]
8.times do |index|
  context.actor, context.now = 'Organizator', 150
  settings = draft('spades').merge('players_per_match' => 4, 'rematch' => true)
  settings['game_options'] = REGISTRY.build('spades').normalize_options('team_size' => 2)
  published = service.publish(**params('spades', draft: settings, intent_id: "ft2_c08_publication_#{index}", timezone: 'local_test:system'))
  assert_equal('confirmed', published['status'])
  row = service.list['announcements'].find { |r| r['publication_key'] == published['values']['publication_key'] }
  NAMES.each do |name|
    context.actor = name
    assert_equal('confirmed', context.service(journal: context.reopen_journal).join(tournament_id: row['__id'])['status'])
  end
  references << {'author' => 'Organizator', 'publication_key' => row['publication_key']}
end
context.actor, context.now = 'Organizator', 201
records = []
with_backend(context) do |backend|
  references.first(8).each_with_index do |reference, index|
    source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
    shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE,
      base_seats: bases(source), intent_id: "ft2_c08_record_#{index}")
    records << backend.accept(preview: shown)
  end
end
records.each do |record|
  match = record['evidence']['plan']['matches'].first
  execution_for(context, record, match['players'].first['username']) do |facade|
    facade.select(intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
state_path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
parent_path = File.join(context.directory, 'plany/fixed-teams-v1/sandbox-k02.json')
before, parent_before = File.binread(state_path), File.binread(parent_path)
state = JSON.parse(before)
assert_equal(records.to_h { |r| [r['preview']['intent_id'], r] }, state['records'])
context.actor = 'Organizator'
service = context.service
error, mutations = c08_observe do
  with_backend(context) do |backend|
    reference = references.last
    source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
    shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE,
      base_seats: bases(source), intent_id: 'ft2_c08_record_8')
    begin
      backend.accept(preview: shown)
    rescue T::Publication::Invalid => failure
      break failure.code
    end
  end
end
oracle_file('ft2_c08_eight_records.json', {records: records, state: state, ninth_error: error, mutations: mutations,
  state_exact: before == File.binread(state_path), parent_exact: parent_before == File.binread(parent_path)})
assert_equal(:sandbox_limit, error, 'Dziewiąty realny legalny plan blokuje już zaufany producent FT1')
assert_equal([], mutations)
assert_equal(before, File.binread(state_path))
assert_equal(parent_before, File.binread(parent_path))
puts 'GREEN C08: osiem rzeczywistych rekordów FT1; dziewiąty odrzucony bez claim FT2 i bez zapisu obu magazynów'
