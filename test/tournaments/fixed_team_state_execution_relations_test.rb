# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert_equal(:bound, facade.request_match[:state])
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
healthy = File.binread(path)
other = record['evidence']['plan']['matches'].fetch(1)['players'].map { |person| person['username'] }
actor = (players & other).first
variants = {
  record_intent: ->(d, e) { e['record_intent'] = 'obcy-rekord' },
  epoch: ->(d, e) { e['epoch'] = false },
  coordinator: ->(d, e) { e['coordinator'] = 'obserwator' },
  grant_fencing: ->(d, e) { e['grant']['fencing'] += 1 },
  grant_holder: ->(d, e) { e['grant']['holder_account'] = players.last.downcase },
  receipt_request: ->(d, e) { e['operations']['reserve']['operation']['request']['execution_generation'] = SecureRandom.uuid },
  receipt_uuid: ->(d, e) { e['operations']['create_bind']['result']['native_uuid'] = SecureRandom.uuid },
  receipt_ready: ->(d, e) { e['operations']['reserve']['result']['ready_versions'].transform_values! { '2' } },
  target_missing: ->(d, e) { e['target'] = nil },
  target_native: ->(d, e) { e['target']['native']['options']['no_hell'] = true },
  native_orphan: ->(d, e) { d['native']['cores'] << JSON.parse(JSON.generate(d['native']['cores'].first)).merge('id' => SecureRandom.uuid) },
  native_metadata: ->(d, e) { d['native']['cores'].first['metadata']['game_options'] = '{}' },
  native_stack: ->(d, e) { d['native']['cores'].first['entries'].first['packet']['kind'] = 'game_started' },
  native_participant: ->(d, e) { d['native']['cores'].first['participants']['obcy'] = {'id' => SecureRandom.uuid, 'user' => 'Obcy'} },
  native_create: ->(d, e) { d['native']['creates'].first['native_uuid'] = SecureRandom.uuid }
}
rows = []
variants.each do |name, mutate|
  document = JSON.parse(healthy); execution = document['executions'].values.first
  mutate.call(document, execution)
  bytes = JSON.generate(document); File.binwrite(path, bytes)
  result = nil
  execution_for(context, record, actor) do |facade|
    select_match(facade, record, 1)
    result = facade.current
  end
  rows << {variant: name, actual: result, before: document, after: JSON.parse(File.binread(path)), exact: File.binread(path) == bytes.b}
end
File.binwrite(path, healthy)
oracle_file('state-execution-relations.json', rows)
rows.each do |row|
  assert(row[:actual][:state] == :blocked && row[:exact], 'RED_FT2A_EXECUTION_RELATIONS: cały niezaznaczony execution i native muszą być sprawdzane przed użyciem stanu')
end
puts 'GREEN: odmowa wszystkich uszkodzonych relacji niezaznaczonego execution i native'
