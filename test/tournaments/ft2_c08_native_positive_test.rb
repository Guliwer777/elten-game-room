# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
class FT2C08ExactNativeLimits < TournamentFixedTeamNativeService
  def initialize(limits); @limits = limits; end
  def limits; @limits; end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
limits = nil; result = nil
execution_for(context, record, players.first) do |facade|
  selection = select_match(facade, record)
  adapter = T::FixedTeamNativeTargetAdapter.new(provider: TournamentFixedTeamNativeService.new, registry: REGISTRY)
  projection = adapter.budget_readback(native: selection[:native], request: selection[:request].to_h, owner: players.first)
  limits = {'options_bytes' => JSON.generate(selection[:native].to_h['options']).bytesize,
    'discovery_bytes' => JSON.generate(projection['discovery']).bytesize,
    'stack_entry_bytes' => JSON.generate(projection['stack'].first['packet']).bytesize,
    'core_bytes' => JSON.generate(adapter.budget_native(projection)).bytesize}
  facade.native_provider = FT2C08ExactNativeLimits.new(limits)
  result = facade.request_match
end
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(path))
oracle_file('ft2_c08_native_positive.json', {limits: limits, actual: result.merge(binding: result[:binding]&.to_h, target: result[:target]&.to_h), state: state})
assert_equal(:bound, result[:state], 'RED_FT2A_C08_NATIVE_POSITIVE: legalne opcje/discovery/packet/core przy właściwej granicy serializera')
target = result[:target].to_h
assert_equal(limits['options_bytes'], target['readback']['table']['game_options'].bytesize)
assert(JSON.generate(target['readback']['discovery']).bytesize <= limits['discovery_bytes'])
assert(JSON.generate(target['readback']['stack'].first['packet']).bytesize <= limits['stack_entry_bytes'])
assert(JSON.generate(state['native']).bytesize <= limits['core_bytes'])
assert_equal(target, state['executions'].values.first['target'])
puts 'GREEN C08: naturalny create przy dodatnich dolnych granicach options/discovery/packet/core'
