# encoding: UTF-8
require_relative '../support/tournament_execution_plan'
require_relative '../support/tournament_coordination_port'
require_relative '../support/tournament_schedule_candidate'
require_relative '../../lib/tournaments/local_readiness_backend'
E = TournamentExecutionPlanFixture
F = TournamentCoordinationFixture
T = GameRoomTournaments
registry = TournamentMatchFixture.registry
observations = []

# Rzeczywisty kandydat D2B1 i rzeczywisty readback K03, bez żywego konta/sieci.
F.isolated do |dir|
  candidate = TournamentScheduleCandidateFixture.build
  own_match = candidate.to_h['matches'].find { |match| match['players'].include?('alice') }
  F.assert(own_match, 'Brak własnego testowego meczu')
  backend = T::LocalReadinessBackend.new(directory: File.join(dir,'k03'), actor: 'Alice',
    clock: -> {200}, source: ->(_reference) {candidate})
  anchor = backend.accept(candidate: candidate)
  target = backend.target(plan_id: anchor['plan_id'], match_id: own_match['match_id'])
  accepted = backend.snapshot(**target)['accepted_match']
  F.assert(accepted['roles_status']=='confirmed', 'Nie uzyskano prawdziwego accepted_match K03')
  before = Dir.glob(File.join(dir,'**','*')).select { |path| File.file?(path) }.to_h { |path| [path,File.binread(path)] }
  effects = []
  observer = TracePoint.new(:call) do |event|
    effects << event.method_id if %i[claim reserve create_bind invite_user start_game request_match].include?(event.method_id)
  end
  observer.enable(target_thread:nil)
  begin
    E.reject(:invalid_json) { E.request(candidate, expected_source:E.anchor(E.evidence)) }
    [candidate.to_h, accepted].each { |value| E.reject(:invalid_fields) { E.request(value, expected_source:E.anchor(E.evidence)) } }
  ensure
    observer.disable
  end
  F.assert(effects.empty?, 'Kandydat/K03 wywołał skutki')
  after = Dir.glob(File.join(dir,'**','*')).select { |path| File.file?(path) }.to_h { |path| [path,File.binread(path)] }
  F.assert(before.eql?(after), 'Odmowa zmieniła trwałe dane')
  observations << {name:'kandydat_i_k03',effects:effects,accepted_match:accepted,unchanged:true}
end

# F.context to wyłącznie test komponentu, NIE dowód lifecycle/auth/EntryContext.
factory = ->(port,dir,context) { T::CoordinationService.new(port:port,trusted_identity:'fixture:owner',
  directory:dir,registry:registry,context: -> {context}) }
F.isolated do |dir|
  request=E.request; port=TournamentCoordinationPort.new(request.to_h)
  result=factory.call(port,dir,F.context).request_match(request:request)
  F.assert(result[:state]==:bound && result[:binding].is_a?(T::MatchBinding), 'Brak dodatniego bound')
  F.assert(port.calls.count(:reserve_before)==1 && port.calls.count(:create_before)==1, 'Nie dokładnie jedna mutacja')
  F.assert(result[:binding].to_h['players'].eql?(request.to_h['players']), 'Zmienione role w bindingu')
  F.assert(!port.calls.any? { |name| name.to_s.match?(/invite|start/) }, 'Nieoczekiwane zaproszenie/start')
  observations << {name:'dodatni_bound',state:result[:state],operation_id:result[:operation_id],calls:port.calls}
end

[:capability,:identity,:context,:snapshot,:withdrawn,:closed].each do |mode|
  F.isolated do |dir|
    request=E.request; port=TournamentCoordinationPort.new(request.to_h); context=F.context
    case mode
    when :capability then port.capabilities.delete('sealed_plan')
    when :identity then port.define_singleton_method(:identity) {'obcy-backend'}
    when :context then context['generation']='obca-generacja'
    when :snapshot
      port.hook=->(event,value) { value['request']['execution_generation']='inna' if event==:snapshot }
    when :withdrawn then port.ready['alice']['state']='withdrawn'
    when :closed then port.time=200
    end
    result=factory.call(port,dir,context).request_match(request:request)
    F.assert(%i[blocked coordination_unavailable].include?(result[:state]), "Brak odmowy #{mode}")
    F.assert(!port.calls.include?(:reserve_before) && !port.calls.include?(:create_before), 'Odmowa po skutku')
    documents=Dir.glob(File.join(dir,'coordination-v1','*.json'))
    F.assert(documents.empty?, 'Odmowa utworzyła operację')
    observations << {name:mode,state:result[:state],reason:result[:reason],calls:port.calls,documents:documents}
  end
end

F.isolated do |dir|
  request=E.request; port=TournamentCoordinationPort.new(request.to_h)
  primary=RuntimeError.new('Testowy błąd programu'); cause=ArgumentError.new('Testowa przyczyna')
  primary.set_backtrace(['testowy-pierwotny:7'])
  port.hook=->(event,_) { raise primary,cause:cause if event==:create_before }
  begin
    factory.call(port,dir,F.context).request_match(request:request)
    raise 'Zamaskowany błąd programu'
  rescue RuntimeError => error
    F.assert(error.equal?(primary) && error.cause.equal?(cause) && error.backtrace==['testowy-pierwotny:7'], 'Utrata primary/cause/backtrace')
  end
  F.assert(port.calls.count(:create_before)==1 && !port.calls.include?(:create_stored), 'Nieoczekiwane ponowienie')
end
if ENV['ENTRY_EVIDENCE']
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'observations.json'),JSON.pretty_generate(observations))
end
puts 'PASS kompozycja: prawdziwy kandydat/K03 odrzucone, bound, capability/tożsamość/kontekst/snapshot/gotowość/okno, primary'
