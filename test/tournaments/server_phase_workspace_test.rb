require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_workspace'
require_relative '../support/tournament_server_plan_table'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require_relative '../../lib/tournaments/server_trial_workspace'
include TournamentLocalWorkspaceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
sandbox do |c|
  ordinary=T::LocalTestTables.new(directory:File.join(c.directory,'simulated-server'),user:-> {c.user},clock:-> {c.now})
  plans=TournamentServerPlanTableSupport::Table.new(user:-> {c.user})
  provider=Object.new
  provider.define_singleton_method(:fetch){|name|name=='tournament_plan_documents' ? plans : ordinary.fetch(name)}
  provider.define_singleton_method(:available?){true}
  build=-> {T::ServerTrialWorkspace.new(program:c.program,registry:GameRoomGames::CATALOG,user:-> {c.user},alert:->(message){c.alerts<<message},clock:-> {c.now},provider_factory:-> {provider})}
  organizer=build.call
  values=params(timezone:'UTC')
  values[:draft]=values[:draft].merge('format'=>'groups_knockout','group_advancement'=>T::GroupAdvancement::COMPACT,'group_count'=>nil,'places_per_group'=>nil,'rematch'=>false)
  record=organizer.publish(**values)
  id=record['evidence']['canonical_id']
  row=organizer.load['announcements'].first
  reference={'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}
  %w[Second Third Fourth].each{|name|c.user=name;build.call.join(id)}
  c.now=201
  c.user='RealOwner'
  root=organizer.shared_schedule(publication_ref:reference)['candidate']
  assert_equal(:phase_results_incomplete,organizer.advance_phase(publication_ref:reference,expected_schedule_id:root['schedule_id'])[:reason])
  # Authenticated transport fixtures exercise workspace wiring, not gameplay.
  # Actual native game histories are covered by server_phase_native_test.
  root['matches'].each_with_index do |match,index|
    creator=T::MatchOrder.players(root['matches'],match).first
    c.user=creator=='realowner' ? 'RealOwner' : creator.capitalize
    service=T::OrdinaryMatchService.new(program:c.program,registry:GameRoomGames::CATALOG,lobby:nil,games:nil,transport:nil,table:plans,
      journal:T::OperationJournal.new(directory:File.join(c.directory,'fixture-bindings'),owner:creator,backend_identity:T::ServerTrialWorkspace::IDENTITY+':ordinary-match-v1'),
      source:-> {{'candidate'=>root,'tournament_id'=>id}},user:-> {c.user})
    begin
      binding=T::Publication::Data.copy({'kind'=>'ordinary-match-binding-v1','schedule_id'=>root['schedule_id'],'match_id'=>match['match_id'],'leg'=>match['leg'],
        'creator'=>creator,'game_id'=>root['game_id'],'options'=>root['game_options'],'session_id'=>index+1,'publication_ref'=>root['publication_ref'],
        'table'=>{'__id'=>index+1,'__live_session_id'=>"fixture-session-#{index}",'owner'=>c.user,'game'=>root['game_id']},
        'players'=>T::MatchOrder.players(root['matches'],match).each_with_index.map{|account,seat|{'account'=>account,'username'=>account,'seat'=>seat}}})
      receipt={'kind'=>'ordinary-match-result-v1','match_id'=>match['match_id'],'leg'=>match['leg'],'session_id'=>index+1,
        'binding_digest'=>Digest::SHA256.hexdigest(JSON.generate(binding)),'history_digest'=>'e'*64,'publication_ref'=>root['publication_ref'],
        'summary'=>{'participants'=>match['players'].sort,'winners'=>[creator],'draw'=>false,'scores'=>nil,'event_count'=>7}}
      [[binding,'binding'],[receipt,'result']].each do |document,kind|
        anchor=service.send(:anchor,root,id,match,kind)
        T::ServerPlanDocument.encode(document,anchor:anchor).each{|values|plans.insert(values)}
      end
    ensure
      service.close
    end
  end
  c.user='RealOwner'
  assert(organizer.load['announcements'].none?{|item|item['sporting_completed']},'Finishing groups incorrectly ended the tournament')
  advanced=organizer.advance_phase(publication_ref:reference,expected_schedule_id:root['schedule_id'])
  assert(advanced,"Phase advance failed: #{organizer.last_error.inspect}; #{c.alerts.inspect}")
  assert_equal('knockout',advanced['candidate']['format'])
  observed=organizer.shared_schedule(publication_ref:reference)
  assert_equal('confirmed',observed['storage'])
  assert_equal(1,observed['phase_history'].size)
  operation=organizer.operations.find{|entry|entry['kind']=='plan_document' && JSON.parse(entry['values']['document_json'])['kind']=='server-sporting-phase-v1'}
  before=plans.insert_count
  assert_equal('confirmed',organizer.reconcile(operation['id'])['status'])
  assert_equal(before,plans.insert_count,'Workspace recovery resent a phase')
  c.user='Second'
  c.path=File.join(c.directory,'second-client')
  assert_equal(observed,build.call.shared_schedule(publication_ref:reference),'Workspace cold reader lost current phase/history')
  assert_equal([],c.alerts)
end
puts 'PASS Tasks workspace phase integration: complete scoped registrations, real-case author lookup, authenticated transport fixtures, observed next phase/history, Operations readback and cold separate-client reader'
