require_relative '../support/tournament_team_dispatch'
require_relative '../../lib/tournaments/local_fixed_team_dispatcher'
include TournamentTeamDispatchSupport
$stdout.sync = true
names = %w[Ala Anna Bartek Beata]
context, service, reference = fixture(names: names, rematch: true, group_advancement: T::GroupAdvancement::AUTOMATIC,
  game_options: ARGV.include?('--finish') ? {'score_limit' => 1} : {})
record = nil
with_backend(context) do |backend|
  record = backend.accept(preview: backend.preview_pairs(publication_ref: reference,
    pairs: names.each_slice(2).to_a, team_template: TEMPLATE, intent_id: 'teams-direct-dispatch'))
end
intent = record['preview']['intent_id']
context.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
dispatch = lambda do |actor, &block|
  actor_backend(context, actor) do |backend, authority, directory|
    block.call(T::LocalFixedTeamDispatcher.new(plan_backend: backend, plan_directory: directory,
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { context.now }, policy_ref: 'teams-direct-final-test', expires_at: nil))
  end
end
dispatch.call('Organizator') { |d| d.configure(intent_id: intent, max_tables: 3) }
names.each { |actor| dispatch.call(actor) { |d| d.available(intent_id: intent, available: true) } }
2.times { names.each { |actor| dispatch.call(actor) { |d| d.advance(intent_id: intent) } } }
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.read(path))
assert_equal(1, state['native']['cores'].size)
assert_equal(4, state['busy'].size)
assert_equal(3, state['native']['cores'].first['invitations'].size)
assert_equal(1, state['native']['cores'].first['participants'].size)
names.each { |actor| dispatch.call(actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
names.each { |actor| dispatch.call(actor) { |d| d.advance(intent_id: intent) } }
state = JSON.parse(File.read(path))
assert_equal(1, state['executions'].values.count { |row| row['start'] })
assert_equal([2, 2], state['executions'].values.first['request']['players'].group_by { |person| person['team'] }.values.map(&:size))
before = File.binread(path)
names.each { |actor| dispatch.call(actor) { |d| d.advance(intent_id: intent) } }
assert_equal(before, File.binread(path))
puts 'PASS direct team dispatch: one final table, own admission, three invitations, full teams and idempotent Start'
if ARGV.include?('--finish')
  row = state['executions'].values.first
  observer = Object.new
  observer.instance_variable_set(:@signals, 0)
  def observer.signal; @signals += 1; end
  dispatch.call(names.first) do |d|
    identity = d.instance_variable_get(:@storage).identity
    subscription = T::LocalDispatchEvents.subscribe(identity, observer)
    begin
      finish_team_dispatch_board(context, record, row, finalize: false)
      assert_equal(1, observer.instance_variable_get(:@signals))
    ensure
      subscription.close
    end
  end
  assert_equal(nil, JSON.parse(File.read(path))['executions'].values.first['result'])
  coordinator = row['request']['players'].find { |person| person['account'] == row['coordinator'] }['username']
  dispatch.call(coordinator) { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
  with_team_match(context, record, names.first) do |execution|
    progress = execution.progress
    assert_equal('completed', progress['knockout_state'])
    assert_equal(progress['qualified'].first, progress['champion'])
    assert_equal(1, progress['standings'].sum { |row| row['wins'] })
  end
  assert_equal({}, JSON.parse(File.read(path))['busy'])
  with_backend(context) { |backend| assert_equal(record, backend.readback(intent_id: intent)) }
  puts 'PASS played team final: real Spades Runner actions, durable result, champion and busy release'
end
