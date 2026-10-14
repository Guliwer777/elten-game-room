# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class OpoznionyEndpointFT2
  def initialize(real); @real = real; end
  def create(**args)
    value = @real.create(**args)
    sleep 1.1
    value
  end
  def method_missing(name, *args, **options, &block); @real.public_send(name, *args, **options, &block); end
  def respond_to_missing?(name, include_private = false); @real.respond_to?(name, include_private); end
end
class OpoznionyProviderFT2 < TournamentFixedTeamNativeService
  def open(**args)
    transaction = super
    transaction.program.live_sessions = OpoznionyEndpointFT2.new(transaction.program.live_sessions)
    transaction
  end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
result = nil
observed = []
tracker = TracePoint.new(:call) do |point|
  if point.defined_class == T::FixedTeamBoundTarget.singleton_class && point.method_id == :build
    observed << JSON.parse(JSON.generate(point.binding.local_variable_get(:readback)))
  end
end
tracker.enable(target_thread: nil)
execution_for(context, record, players.first, native_provider: OpoznionyProviderFT2.new) do |facade|
  select_match(facade, record)
  result = facade.request_match
end
tracker.disable
oracle_file('native-time-observed.json', observed)
oracle_file('native-time-boundary.json', result.merge(target: result[:target]&.to_h, binding: result[:binding]&.to_h))
assert(result[:state] == :bound, 'RED_FT2A_NATIVE_TIME: legalny upływ czasu między create a room_created nie może odrzucać celu')
assert(result[:target].to_h['readback']['stack'].first['created_at'] > result[:target].to_h['readback']['metadata']['created_at'])
puts 'GREEN: rzeczywiste create i room_created mogą mieć różne poprawne czasy'
