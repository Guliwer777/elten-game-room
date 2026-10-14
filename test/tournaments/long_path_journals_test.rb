require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_readiness_fixture'
require_relative '../support/tournament_coordination_port'
require_relative '../../lib/tournaments/readiness_history'

R = TournamentReadinessFixture
K = TournamentCoordinationFixture
R.isolated do |root|
  directory = File.join(root, 'x' * (205 - root.bytesize - 1))
  port = R::Port.new
  context = R::Context.new
  first = R.service(directory, port, context).declare(request: R.request)
  R.assert(first[:state] == :confirmed, 'Long readiness path confirmed')
  again = R.service(directory, port, context).declare(request: R.request)
  R.assert(again[:operation_id] == first[:operation_id] && port.calls.count(:store_before) == 1,
    'Cold restart retains readiness identity without duplicate store')
  history = GameRoomTournaments::ReadinessHistory.new(directory: directory,
    context: context.method(:call), identity: 'fixture:k03')
  R.assert(history.records(scope: R.scope, match_ref: R.match_ref).length == 1,
    'History reads the same long-path readiness journal')

  request = K.request
  coordinator = TournamentCoordinationPort.new(request)
  factory = -> { GameRoomTournaments::CoordinationService.new(port: coordinator,
    trusted_identity: 'fixture:owner', directory: directory,
    registry: TournamentMatchFixture.registry, context: -> { K.context }) }
  R.assert(factory.call.request_match(request: request)[:state] == :bound,
    'Long coordination path binds match')
  R.assert(factory.call.reconcile(request: request)[:state] == :bound &&
    coordinator.calls.count(:reserve_before) == 1 && coordinator.calls.count(:create_before) == 1,
    'Cold restart preserves binding without duplicate reserve or create')
end
puts JSON.generate({passed: 2, description: 'Long-path readiness, history and coordination with cold restart'})
