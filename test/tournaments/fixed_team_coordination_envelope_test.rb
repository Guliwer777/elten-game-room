# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
class OgraniczonyTransportFT2Completion
  def initialize(port, limit); @port, @limit = port, limit; end
  def identity; @port.identity; end
  def negotiate(**values); @port.negotiate(**values).merge('max_bytes' => @limit); end
  def snapshot(**values); @port.snapshot(**values); end
  def reserve(**values); @port.reserve(**values); end
  def create_bind(**values); @port.create_bind(**values); end
  def lookup(**values); @port.lookup(**values); end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
actor_backend(context, players.first) do |backend, authority, directory|
  window = record['evidence']['plan']['matches'].first['windows'].first
  facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
    source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
    clock: -> { window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
  facade.native_provider = TournamentFixedTeamNativeService.new
  request = select_match(facade, record)[:request]
  port = facade.send(:coordination_port)
  view = port.snapshot(request: request.to_h)
  op = T::CoordinationContract.operation(kind: 'reserve', request: request.to_h, actor: players.first.downcase,
    operation_id: SecureRandom.uuid, preconditions: {'expected_revision' => view['resource_revision'],
      'ready_versions' => view['ready'].transform_values { |row| row['revision'] }, 'window' => request.to_h['window'], 'grant' => nil})
  limit = JSON.generate(op).bytesize + 1
  context_bridge = T::LocalFixedTeamExecutionContext.new(authority: authority, request: request, coordinator_events: port.events)
  service = T::CoordinationService.new(port: OgraniczonyTransportFT2Completion.new(port, limit), trusted_identity: port.identity,
    directory: File.join(directory, 'fixed-teams-v1/execution-ft2-v1/journals'), registry: REGISTRY, context: context_bridge.method(:call))
  path = File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')
  before = File.binread(path); claims = []
  trace = TracePoint.new(:call) { |p| claims << p.method_id if p.defined_class == T::CoordinationJournal && p.method_id == :claim }
  begin
    trace.enable(target_thread: nil)
    result = service.request_match(request: request)
  ensure
    trace.disable
  end
  oracle_file('coordination-envelope.json', {operation: op, limit: limit, claims: claims, result: result.merge(binding: result[:binding]&.to_h),
    before: JSON.parse(before), after: JSON.parse(File.binread(path))})
  assert(result[:state] == :blocked && result[:reason] == :payload_too_large && claims.empty? && File.binread(path) == before,
    'RED_FT2A_FULL_ENVELOPE: wysyłalne operation nie wystarcza; pełny response musi zmieścić się przed claim')
end
puts 'GREEN: pełny envelope według niższego limitu transportu przed claim'
