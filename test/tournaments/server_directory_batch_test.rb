require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments

sandbox do |c|
  public_tables=T::LocalTestTables.new(directory:File.join(c.directory,'server'),user:-> {c.user},clock:-> {c.now})
  docs=TournamentServerPlanTableSupport::Table.new(user:-> {c.user})
  reads=0
  docs.on_select=-> {reads+=1}
  provider=Object.new
  provider.define_singleton_method(:available?){true}
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? docs : public_tables.fetch(name)}
  build=-> {T::ServerWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},
    alert:->(text){c.alerts<<text},clock:-> {c.now},readiness_clock:-> {c.now},provider_factory:-> {provider})}
  workspace=build.call
  24.times do |i|
    values=params('tic_tac_toe',timezone:'UTC',intent_id:"publish-#{i}")
    values[:draft]=values[:draft].merge('name'=>"Batch #{i}",'rematch'=>true)
    publication=workspace.publish(**values)
    assert_equal('confirmed',publication&.fetch('status'),[c.alerts,workspace.last_error&.message,workspace.last_error&.cause&.message].inspect)
    c.user='Second'
    assert_equal('confirmed',build.call.join(publication['evidence']['canonical_id'])&.fetch('status'),c.alerts.inspect)
    c.user='RealOwner'
  end
  # A nonempty document table prevents the empty-table fast path from hiding
  # repeated per-tournament queries.
  docs.insert('operation_key'=>'f'*64)
  c.now=201
  unbatched=build.call
  unbatched.define_singleton_method(:prefetch_directory_documents){|*|nil}
  before=reads
  expected=unbatched.load
  unbatched_reads=reads-before
  before=reads
  actual=workspace.load
  batched_reads=reads-before
  assert_equal(expected,actual,'Batching changed directory contents')
  assert_equal(24,actual.fetch('announcements').size)
  assert_equal(1,docs.insert_count,'Directory reads wrote documents')
  assert(batched_reads<=7,"Too many batched document reads: #{batched_reads}")
  assert(batched_reads*4<unbatched_reads,"No material reduction: #{unbatched_reads} -> #{batched_reads}")
  first=actual.fetch('announcements').first
  ref={'author'=>first['__insertion_user'],'publication_key'=>first['publication_key']}
  source=workspace.read_operation{workspace.send(:server_source,ref)}
  reader=workspace.ordinary_service(publication_ref:ref,lobby:nil,games:nil,transport:nil)
  begin
    key=reader.result_document_keys(source['candidate'],first['__id']).fetch(3)
    # Malformed organizer evidence remains a per-tournament error; batching
    # must not convert it to absence or make the whole directory unavailable.
    docs.insert('operation_key'=>key)
    damaged=workspace.load
    assert_equal(24,damaged.fetch('announcements').size)
    assert_equal(unbatched.load,damaged)
    assert(damaged['announcements'].find{|row|row['__id']==first['__id']}['plan_error'])
  ensure
    reader&.close
  end
  # A later operation must see an organizer change, not a retained directory.
  workspace.delete_tournament(first['__id'],'remove-first',T::RegistrationProjection.publication_generation(first))
  fresh=workspace.load
  assert_equal(23,fresh.fetch('announcements').size)
  puts "PASS batched directory: identical 24-tournament projection, fresh deletion, no writes; document reads #{unbatched_reads} -> #{batched_reads}"
end
