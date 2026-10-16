# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
class FT2C08BoundedPort
  def initialize(port, limit); @port, @limit = port, limit; end
  def identity; @port.identity; end
  def negotiate(**input); @port.negotiate(**input).merge('max_bytes' => @limit); end
  def snapshot(**input); @port.snapshot(**input); end
  def reserve(**input); @port.reserve(**input); end
  def create_bind(**input); @port.create_bind(**input); end
  def lookup(**input); @port.lookup(**input); end
  def preflight_operation(**input); @port.preflight_operation(**input); end
end
context, record, players, path, healthy = c08_bound_fixture
receipts = JSON.parse(healthy)['executions'].values.first['operations']
limit = receipts.values.map { |r| JSON.generate(r).bytesize }.max + 256
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + '-near-limit')
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
actual = nil
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  request = select_match(facade, record)[:request]
  port = facade.send(:coordination_port)
  authority = facade.instance_variable_get(:@context)
  bridge = T::LocalFixedTeamExecutionContext.new(authority: authority, request: request, coordinator_events: port.events)
  service = T::CoordinationService.new(port: FT2C08BoundedPort.new(port, limit), trusted_identity: port.identity,
    registry: REGISTRY, context: bridge.method(:call), directory: File.join(File.dirname(path), 'near-limit-journal'))
  result = service.request_match(request: request)
  actual = result.merge(binding: result[:binding]&.to_h)
end
state_path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(state_path))
oracle_file('ft2_c08_envelope_positive.json', {limit: limit, measured_receipts: receipts, actual: actual, state: state})
assert_equal(:bound, actual[:state], 'RED_FT2A_C08_NATURAL_ENVELOPE: legalny rzeczywisty envelope mieści się blisko dolnego limitu; maksymalne fikcyjne teksty nie mogą go blokować')
assert_equal(1, state['native']['creates'].size)
state['executions'].values.first['operations'].each_value { |r| assert(JSON.generate(r).bytesize <= limit) }
puts 'GREEN C08: rzeczywisty lokalny envelope blisko niższego limitu bez nadmiarowej projekcji'
