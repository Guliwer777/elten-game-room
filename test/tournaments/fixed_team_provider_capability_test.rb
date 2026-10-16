# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class NiepelnyNativeProviderFT2
  def initialize; @real = TournamentFixedTeamNativeService.new; end
  def local_transaction_version; @real.local_transaction_version; end
  def limits; @real.limits; end
  def open(**values); @real.open(**values); end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1/execution-ft2-v1/state.json')
before = File.binread(path)
result = caught = nil; claims = []
trace = TracePoint.new(:call) { |p| claims << p.method_id if p.defined_class == T::CoordinationJournal && p.method_id == :claim }
execution_for(context, record, players.first, native_provider: NiepelnyNativeProviderFT2.new) do |facade|
  select_match(facade, record)
  begin
    trace.enable(target_thread: nil)
    result = facade.request_match
  rescue NoMethodError => error
    caught = error
  ensure
    trace.disable
  end
end
oracle_file('provider-capability.json', {result: result, error: caught && {class: caught.class.name, message: caught.message, backtrace: caught.backtrace},
  claims: claims, before: JSON.parse(before), after: JSON.parse(File.binread(path))})
assert(!caught && result[:state] == :coordination_unavailable && claims.empty? && File.binread(path) == before,
  'RED_FT2A_CAPABILITY: niepełny kontrakt providera musi odmówić przed zapisem, nie zgłaszać NoMethodError po commit')
puts 'GREEN: brak wymaganej zdolności providera odmawia przed claim i zapisem'
