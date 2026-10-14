# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
class FT2C08SharedPort
  def initialize(port, limit); @port, @limit = port, limit; end
  def identity; @port.identity; end
  def negotiate(**input); @port.negotiate(**input).merge('max_bytes' => @limit); end
  def snapshot(**input); @port.snapshot(**input); end
  def lookup(**input); @port.lookup(**input); end
  def preflight_operation(**input); @port.preflight_operation(**input); end
end
context, record, players, path, healthy = c08_bound_fixture
receipts = JSON.parse(healthy)['executions'].values.first['operations']
limit = JSON.generate(receipts['reserve']).bytesize + 1
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  request = select_match(facade, record)[:request]
  port = facade.send(:coordination_port)
  bridge = T::LocalFixedTeamExecutionContext.new(authority: facade.instance_variable_get(:@context), request: request, coordinator_events: port.events)
  service = T::CoordinationService.new(port: FT2C08SharedPort.new(port, limit), trusted_identity: port.identity,
    registry: REGISTRY, context: bridge.method(:call), directory: File.join(File.dirname(path), 'new-shared-journal'))
  result, mutations = c08_observe { service.reconcile(request: request) }
  actual = {result: result.merge(binding: result[:binding]&.to_h), mutations: mutations, exact: File.binread(path) == healthy}
  expected = {result: {state: :blocked, reason: :payload_too_large, operation_id: nil, binding: nil}, mutations: [], exact: true}
  oracle_file('ft2_c08_shared_envelope.json', {expected: expected, actual: actual, limit: limit, receipts: receipts})
  assert_equal(expected, actual, 'RED_FT2A_C08_SHARED_ENVELOPE: wszystkie shared envelopes trzeba sprawdzić przed pierwszym import claim')
end
puts 'GREEN C08: shared/import pełnego zbioru przed pierwszym claim'
