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
rows = []
[:metadata, :discovery, :stack, :participants].each do |variant|
  document = JSON.parse(healthy); execution = document['executions'].values.first
  readback = execution['target']['readback']; core = document['native']['cores'].first
  case variant
  when :metadata, :discovery
    options = JSON.parse(readback[variant.to_s]['game_options']); options['no_hell'] = true
    readback[variant.to_s]['game_options'] = JSON.generate(options)
  when :stack
    readback['stack'].first['packet']['data']['owner'] = players.last
  when :participants
    readback['participants'] = {'obcy' => {'id' => SecureRandom.uuid, 'user' => 'Obcy'}}
  end
  core['metadata'] = readback['metadata']; core['discovery_metadata'] = readback['discovery']
  core['entries'] = readback['stack']; core['participants'] = readback['participants']
  document['native']['creates'].first['arguments']['metadata'] = core['metadata']
  document['native']['creates'].first['arguments']['discovery_metadata'] = core['discovery_metadata']
  bytes = JSON.generate(document); File.binwrite(path, bytes)
  result = nil
  execution_for(context, record, players.first) do |facade|
    select_match(facade, record)
    result = facade.current
  end
  rows << {variant: variant, actual: result, before: document, after: JSON.parse(File.binread(path)), exact: File.binread(path) == bytes.b}
end
File.binwrite(path, healthy)
oracle_file('native-cross-relations.json', rows)
rows.each { |row| assert(row[:actual][:state] == :blocked && row[:exact], 'RED_FT2A_NATIVE_CROSS: zgodne echo core i target nie zastępuje zgodności z autorytetem FT1') }
puts 'GREEN: metadata/discovery/stack/participants sprawdzane względem native i request, nie wzajemnego echa'
