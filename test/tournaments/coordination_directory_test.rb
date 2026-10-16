require_relative '../support/tournament_local_workspace'
require_relative '../support/readiness_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_coordination'
require_relative '../../lib/tournaments/view_refresh'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments

sandbox do |c|
  ordinary=T::LocalTestTables.new(directory:File.join(c.directory,'server'),user:-> {c.user},clock:-> {c.now})
  plans=ReadinessPlanTableSupport::Table.new(user:-> {c.user},clock:-> {c.now})
  provider=Object.new
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? plans : ordinary.fetch(name)}
  provider.define_singleton_method(:available?){true}
  changed=[]
  klass=Class.new
  klass.define_singleton_method(:tournament_changed){|ref|changed<<ref}
  program=klass.new
  program.define_singleton_method(:data_path){c.path}
  build=-> {T::ServerWorkspace.new(program:program,registry:GameRoomGames::CATALOG,user:-> {c.user},
    alert:->(message){raise message},clock:-> {c.now},readiness_clock:-> {c.now},provider_factory:-> {provider})}
  owner=build.call
  record=owner.publish(**params('tic_tac_toe',timezone:'UTC',draft:draft('tic_tac_toe').merge('windows'=>[],'starts_at'=>0,'deadline_at'=>0),
    registration_opens_at:100,registration_closes_at:0))
  id=record['evidence']['canonical_id']
  row=owner.load['announcements'].first
  ref={'author'=>'realowner','publication_key'=>row['publication_key']}
  worker=Object.new
  worker.define_singleton_method(:close){}
  wakes=[]
  co=T::ServerCoordination.new(workspace:owner,user:-> {c.user},clock:-> {c.now},worker:worker,
    wake:->(*args){wakes<<args})
  before=co.coordinate(ref)
  assert_equal(1,before['directory']['members'].size)
  c.user='SecondPlayer'
  guest=build.call
  assert_equal('confirmed',guest.join(id)['status'])
  assert_equal(ref,changed.last,'Enrollment did not queue a change')
  c.user='RealOwner'
  joined=co.coordinate(ref,sender:'secondplayer')
  assert_equal(2,joined['directory']['members'].size)
  assert_raises(T::ProposalNotice::Stale){co.coordinate(ref,sender:'unrelated')}
  co.coordinate(ref,broadcast:true)
  assert_equal([['secondplayer',ref]],wakes)
  c.user='SecondPlayer'
  assert_equal('confirmed',guest.withdraw(id)['status'])
  c.user='RealOwner'
  left=co.coordinate(ref,sender:'secondplayer')
  assert_equal(1,left['directory']['members'].size,'A confirmed withdrawal could not wake the view')
  owner.delete_tournament(id,'cancel',T::RegistrationProjection.publication_generation(row))
  assert_equal(nil,co.coordinate(ref,broadcast:true)['directory']['publication'],'Cancellation left a stale publication')
ensure
  co&.close
end

revision=1
klass=Class.new
klass.define_singleton_method(:tournament_view_revision){|_|revision}
reads=0
view=T::ViewRefresh.new(klass.new){reads+=1}
20.times{view.tick}
assert_equal(0,reads,'View polling without a change')
revision+=1
view.tick
20.times{view.tick}
assert_equal(1,reads)
revision+=1
view.acknowledge
view.tick
assert_equal(1,reads,'An explicit refresh caused a duplicate read')
puts 'PASS authenticated pre-start updates, join/withdraw/cancel, unrelated sender rejection and no view polling'
