require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_dispatcher'
include TournamentFixedTeamExecutionSupport
names = %w[Ala Anna Bartek Beata Celina Cezary Daria Daniel]
context, service, reference = fixture(names: names, rematch: false)
units = names.each_slice(2).each_with_index.map { |people, index| {'unit_id' => "team-#{index}", 'accounts' => people.map(&:downcase)} }
roster = {'version' => 1, 'kind' => 'fixed-teams', 'units' => units}
template = [0,0,1,1]
source = service.fixed_team_execution_source(publication_ref: reference, membership: roster, team_template: template)
seats = source['candidate']['matches'].select { |row| row['leg'] == 1 }.to_h { |row| [row['match_id'], row['players']] }
record = nil
with_backend(context) { |backend| record = backend.accept(preview: backend.preview(publication_ref: reference, membership: roster, team_template: template, base_seats: seats, intent_id: 'teams-auto')) }
intent = record['preview']['intent_id']
context.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
with_dispatch = lambda do |actor, &block|
  actor_backend(context, actor) do |backend, authority, directory|
    block.call(T::LocalFixedTeamDispatcher.new(plan_backend: backend, plan_directory: directory,
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { context.now }, policy_ref: 'teams-automatic-test', expires_at: nil))
  end
end
with_dispatch.call('Organizator') { |d| d.configure(intent_id: intent, max_tables: 2) }
names.each { |actor| with_dispatch.call(actor) { |d| d.available(intent_id: intent, available: true) } }
2.times { names.each { |actor| with_dispatch.call(actor) { |d| d.advance(intent_id: intent) } } }
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.read(path))
assert_equal(2, state['native']['cores'].size)
assert_equal(8, state['busy'].size)
assert_equal(6, state['native']['cores'].sum { |row| row['invitations'].size })
assert(state['native']['cores'].all? { |row| row['participants'].size == 1 }, 'Invitation must not fabricate admission')
assert(state['executions'].values.all? { |row| row['request']['players'].group_by { |person| person['team'] }.values.all? { |people| people.size == 2 } }, 'Accepted team assignment lost')
names.each { |actor| with_dispatch.call(actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
names.each { |actor| with_dispatch.call(actor) { |d| d.advance(intent_id: intent) } }
state = JSON.parse(File.read(path))
assert_equal(2, state['executions'].values.count { |row| row['start'] })
assert_equal(2, state['native']['creates'].size)
before = File.binread(path)
names.each { |actor| with_dispatch.call(actor) { |d| d.advance(intent_id: intent) } }
assert_equal(before, File.binread(path))
context.now = record['evidence']['plan']['matches'].flat_map { |row| row['windows'] }.map { |window| window['closes'] }.max
names.each do |actor|
  with_dispatch.call(actor) do |d|
    effect = d.advance(intent_id: intent)
    assert_equal(:blocked, effect[:state])
    assert_equal(:execution_interrupted, effect[:reason])
  end
end
assert_equal(before, File.binread(path))
assert_equal(8, JSON.parse(File.binread(path))['busy'].size)
puts 'PASS fixed-team dispatcher: same queue, two disjoint four-seat native tables, six invitations, own admission, preserved teams and single Start'
