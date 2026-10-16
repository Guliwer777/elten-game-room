# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
include TournamentFixedTeamExecutionSupport
native_provider = TournamentFixedTeamNativeService.new
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.first(3).each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
execution_for(context, record, players.first, native_provider: native_provider) do |facade|
  select_match(facade, record)
  assert(facade.respond_to?(:request_match), 'RED_FT2A_KOORDYNACJA: gotowość FT1 nie ma rzeczywistego przejścia do CoordinationService')
  result = facade.request_match
  assert_equal(:not_all_ready, result[:reason], 'Trzy osoby nie rezerwują meczu')
end
execution_for(context, record, players.last) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
end
assert(T::LocalFixedTeamCoordinationPort.instance_methods.include?(:create_bind),
  'RED_FT2A_CEL: brak trwałego create_bind po gotowości czterech osób')
results = []
2.times do
  execution_for(context, record, players.first, native_provider: native_provider) do |facade|
    selected = select_match(facade, record)
    result = facade.request_match
    assert_equal(:bound, result[:state], 'Rzeczywisty CoordinationService potwierdza cel')
    target = result.fetch(:target).to_h
    assert_equal(selected[:native].to_h, target['native'])
    assert_equal(true, target['readback']['table']['private'])
    assert_equal(players.first, target['readback']['table']['owner'])
    assert_equal(0, target['readback']['table']['bot_count'])
    assert_equal(selected[:native].to_h['options'], JSON.parse(target['readback']['table']['game_options']))
    assert_equal(nil, target['readback']['game_instance'])
    assert_equal(1, target['readback']['participants'].size)
    assert_equal(false, target['native']['start_allowed'])
    assert_equal(false, target['native']['dispatch_allowed'])
    results << target
  end
end
assert_equal(results.first, results.last, 'Ponowne wejście nie tworzy nowego celu')
state = JSON.parse(File.binread(File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')))
assert_equal(1, state['native']['creates'].size)
assert_equal(%w[room_created], state['native']['cores'].first['entries'].map { |row| row['packet']['kind'] })
oracle_file('native-target.json', {record: record, targets: results, state: state})
puts 'GREEN: pełna gotowość, trwały prywatny cel i exact odczyt bez zaproszeń oraz Start'
