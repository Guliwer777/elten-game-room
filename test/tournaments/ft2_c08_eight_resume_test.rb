# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
# Wznawiamy wyłącznie niedokończoną odmowę dziewiątego planu, bez powtórzenia ośmiu przyjęć.
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared/eight-records-control-001')
context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator')
context.now = 201
service = context.service
state_path = File.join(directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
parent_path = File.join(directory, 'plany/fixed-teams-v1/sandbox-k02.json')
before, parent_before = File.binread(state_path), File.binread(parent_path)
state, parent = JSON.parse(before), JSON.parse(parent_before)
records = parent['records']
assert_equal(8, records.size)
assert_equal(records.to_h { |r| [r['preview']['intent_id'], r] }, state['records'])
accepted_keys = records.map { |r| r['preview']['source']['candidate']['publication_ref']['publication_key'] }
row = service.list['announcements'].find { |r| !accepted_keys.include?(r['publication_key']) }
reference = {'author' => 'Organizator', 'publication_key' => row.fetch('publication_key')}
error, mutations = c08_observe do
  with_backend(context) do |backend|
    records.each { |r| assert_equal(r, backend.readback(intent_id: r['preview']['intent_id'])) }
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
assert_equal(:sandbox_limit, error)
assert_equal([], mutations)
assert_equal(before, File.binread(state_path))
assert_equal(parent_before, File.binread(parent_path))
puts 'GREEN C08: osiem rzeczywistych rekordów odczytanych; dziewiąty legalny plan blokuje rodzic przed claim FT2'
