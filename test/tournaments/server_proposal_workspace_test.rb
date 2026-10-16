require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_workspace'
require_relative '../support/readiness_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_trial_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
sandbox do |c|
  availability=[]
  c.program.class.define_singleton_method(:tournament_availability_changed) { |ref, ready| availability << [ref, ready] }
  ordinary=T::LocalTestTables.new(directory:File.join(c.directory,'simulated-server'),user:-> {c.user},clock:-> {c.now})
  plans=ReadinessPlanTableSupport::Table.new(user:-> {c.user},clock:-> {c.now})
  provider=Object.new
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? plans : ordinary.fetch(name)}
  provider.define_singleton_method(:available?){true}
  build=-> {T::ServerTrialWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},
    alert:->(message){raise 'Worker spoke directly' unless Thread.current==c.ui_thread;c.alerts<<message},
    clock:-> {c.now},readiness_clock:-> {c.now},provider_factory:-> {provider})}
  organizer=build.call
  record=organizer.publish(**params(timezone:'UTC'))
  id=record['evidence']['canonical_id']
  row=organizer.load['announcements'].find{|item|item['__id']==id}
  reference={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
  c.user='SecondPlayer'
  build.call.join(id)
  c.now=Time.utc(2026,10,15,12).to_i
  c.user='RealOwner'
  organizer=build.call
  plan=organizer.shared_schedule(publication_ref:reference)['candidate']
  match=plan['matches'].first.slice('match_id','leg').transform_keys(&:to_sym)
  assert_equal('missing',organizer.shared_proposal(publication_ref:reference,**match)['state'])
  organizer.shared_readiness(publication_ref:reference,available:true,intent_id:'owner-ready')
  c.user='SecondPlayer'
  player=build.call
  player.shared_readiness(publication_ref:reference,available:true,intent_id:'player-ready')
  availability.clear
  c.user='RealOwner'
  organizer=build.call
  proposed=organizer.shared_proposal(publication_ref:reference,**match,action:'propose',intent_id:'proposal')
  token=proposed['token']
  assert_equal(['realowner'],proposed['accepted'])
  c.user='SecondPlayer'
  player=build.call
  result=player.shared_proposal(publication_ref:reference,**match,action:'decline',token:token,intent_id:'player-decline')
  assert_equal('declined',result['state'])
  assert_equal([],availability,'Invitations changed tournament-wide availability')
  states=player.shared_readiness(publication_ref:reference)['participants'].to_h{|item|[item['account'],item['state']]}
  assert_equal('ready',states['realowner'],'Partner was disabled by another player refusal')
  assert_equal('ready',states['secondplayer'],'Declining a match changed unrelated tournament availability')
  record=player.operations.find{|item|item['intent_id']=='pilot:player-decline'}
  reconciled=player.reconcile(record['id'])
  assert(reconciled,"Pilot reconciliation failed: #{player.last_error.inspect}")
  assert_equal('confirmed',reconciled['status'])
  start_source=player.start_notice_source(publication_ref:reference)
  assert_equal(true,start_source['complete'])
  assert_equal(%w[realowner secondplayer],start_source['participants'])
  assert_equal(row['title'],start_source['publication']['title'])
  assert_equal([],c.alerts)
end
puts 'PASS real Tasks workspace pilot: shared server-table composition, source generation, explicit responses, only refuser unavailable, operations and cold readback, owner-thread alerts'
