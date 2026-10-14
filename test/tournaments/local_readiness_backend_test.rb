# encoding: UTF-8
require_relative '../support/tournament_local_workspace'
require_relative '../../lib/tournaments/local_workspace'
require_relative '../../lib/tournaments/readiness_service'
file=File.expand_path('../../lib/tournaments/local_readiness_backend.rb',__dir__)
require file if File.file?(file)
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
assert(T.const_defined?(:LocalReadinessBackend), 'Brak rzeczywistego backendu sandbox K03')
sandbox do |ctx|
  author=ctx.workspace('Organizator')
  pub=author.publish(**local_params)
  assert_equal('confirmed',pub['status'])
  row=author.load['announcements'].first
  %w[Alicja Bob Celina].each { |actor| assert_equal('confirmed',ctx.workspace(actor).join(row['__id'])['status']) }
  ctx.now=201
  candidate=author.schedule_candidate(publication_ref:{'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']})
  dir=File.join(ctx.directory,'k03-osobno')
  backend=T::LocalReadinessBackend.new(directory:dir,actor:'Alicja',clock:-> {ctx.now},source:->(_ref) {candidate})
  assert_equal([],backend.plans)
  anchor=backend.accept(candidate:candidate)
  assert_equal(candidate.to_h['roster'],anchor['candidate']['roster'])
  assert_equal('observed_candidate',candidate.to_h['state'])
  match=candidate.to_h['matches'].find { |item| item['players'].include?('alicja') }
  target=backend.target(plan_id:anchor['plan_id'],match_id:match['match_id'])
  context={'account'=>'alicja','backend_identity'=>backend.identity,'runtime_id'=>'fixture-runtime',
    'runtime_epoch'=>1,'auth_epoch'=>1,'backend_epoch'=>1,'cancelled'=>false}
  service=T::ReadinessService.new(port:backend,trusted_identity:backend.identity,directory:File.join(ctx.directory,'journal'),context:-> {context})
  result=service.current(**target)
  assert_equal(:confirmed,result[:state])
  assert_equal('unknown',result[:current]['state'])
  request={'version'=>1,'scope'=>target[:scope],'match_ref'=>target[:match_ref],'availability'=>'ready',
    'expected_ready_revision'=>0,'policy_ref'=>T::LocalReadinessBackend::POLICY}
  backend.verify_source(candidate:candidate,plan_id:anchor['plan_id'])
  result=service.declare(request:request)
  assert_equal(:confirmed,result[:state])
  assert_equal('ready',result[:receipt]['result']['state'])
  assert_equal([],result[:receipt]['result']['invalidated_grants'])
  assert_equal(result[:receipt],backend.lookup(operation:result[:receipt]['operation']))
  assert_equal('ready',service.current(**target)[:current]['state'])
end
puts 'PASS lokalny pełny skład → jawny plan → unknown → ready/readback'
