# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
match = record['evidence']['plan']['matches'].first
players = match['players'].map { |person| person['username'] }
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
root = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1')
path = File.join(root, 'state.json')
healthy = File.binread(path)
original = JSON.parse(healthy)
rows = []
other_players = record['evidence']['plan']['matches'].fetch(1)['players'].map { |person| person['username'] }
reader_actor = (players & other_players).first
assert(reader_actor, 'Dwa legalne mecze mają wspólnego uczestnika')
[:brak_osoby, :obcy_mecz, :obca_osoba].each do |variant|
  document = JSON.parse(healthy)
  case variant
  when :brak_osoby then document['busy'].delete(players.first.downcase)
  when :obcy_mecz then document['busy'][players.first.downcase] = 'nieistniejacy-mecz'
  when :obca_osoba then document['busy']['obserwator'] = document['executions'].keys.first
  end
  corrupted = JSON.generate(document)
  File.binwrite(path, corrupted)
  [:current, :declare].each do |action|
    result = error = nil; claims = []
    trace = TracePoint.new(:call) do |point|
      claims << point.method_id if [T::ReadinessJournal, T::CoordinationJournal].include?(point.defined_class) && point.method_id == :claim
    end
    execution_for(context, record, reader_actor) do |facade|
      select_match(facade, record, 1)
      begin
        trace.enable(target_thread: nil)
        result = action == :current ? facade.current : facade.declare(availability: 'ready', expected_revision: 0)
      rescue T::Publication::Invalid, T::ReadinessContract::Blocked => caught
        error = caught
      ensure
        trace.disable
      end
    end
    rows << {variant: variant, action: action, result: result, error: error && {class: error.class.name, code: error.code},
      claims: claims, before: document, after: JSON.parse(File.binread(path)), exact: File.binread(path) == corrupted.b}
  end
end
File.binwrite(path, healthy)
oracle_file('state-busy-relations.json', {healthy: original, cases: rows})
rows.each do |row|
  refused = row[:error] || (row[:result] && row[:result][:state] == :blocked)
  reason = row[:error] ? row[:error][:code] : row[:result] && row[:result][:reason]
  assert(refused && reason == :sandbox_corrupt && row[:claims].empty? && row[:exact], 'RED_FT2A_GLOBAL_BUSY: uszkodzenie niezaznaczonego meczu musi blokować odczyt i nowy claim globalnie')
end
puts 'GREEN: relacja busy całego składu weryfikowana globalnie przed odczytem i nowym claim'
