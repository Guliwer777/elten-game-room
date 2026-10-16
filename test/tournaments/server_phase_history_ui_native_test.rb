require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_server_plan_table'
require_relative '../../lib/tournaments/server_phase_store'
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
fixture=TournamentIndividualUI.fixture
program=fixture[:program]
begin
  seeds=%w[alpha beta gamma delta epsilon zeta eta theta]
  plan=T::KnockoutRound.build(seeds:seeds,players_per_match:2,round_number:1)
  metadata=plan.slice('round','seeds','players_per_match','generation').merge('phase_digest'=>'c'*64,'parent_plan_digest'=>'d'*64)
  schedule,matches=T::KnockoutSchedule.matches(metadata:metadata,generation:'a'*64)
  root={'candidate'=>{'schedule_id'=>schedule,'publication_digest'=>'b'*64,'roster_generation'=>'a'*64,
    'game_id'=>'tic_tac_toe','publication_ref'=>{'author'=>'alpha','publication_key'=>'history-ui'},
    'format'=>'knockout','players_per_match'=>2,'game_options'=>{},'roster'=>seeds,'matches'=>matches,
    'knockout'=>metadata,'state'=>'observed_candidate','finality'=>'unknown',
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false},'tournament_id'=>9}
  documents=TournamentServerPlanTableSupport::Table.new(user:-> {'alpha'})
  journal=T::OperationJournal.new(directory:File.join(fixture[:sandbox],'history-ui'),owner:'alpha',backend_identity:'history-ui')
  receipts={}
  reader=->(candidate,_root){{'results'=>receipts.fetch(candidate['schedule_id'],[]),'standings'=>[]}}
  store=T::ServerPhaseStore.new(table:documents,journal:journal,user:-> {'alpha'},source:-> {root},results:reader)
  ids=[]
  2.times do
    candidate=store.current.fetch('candidate')
    ids << candidate.fetch('schedule_id')
    receipts[candidate['schedule_id']]=candidate['matches'].map do |match|
      {'kind'=>'ordinary-match-result-v1','match_id'=>match['match_id'],'leg'=>match['leg'],
        'summary'=>{'participants'=>match['players'].sort,'winners'=>[match['players'].first],
          'draw'=>false,'scores'=>nil,'event_count'=>7}}
    end
    store.advance(expected_schedule_id:candidate['schedule_id'])
  end
  observed=store.current
  # Use the actual compact producer output, not full synthetic candidates.
  assert_equal(ids,observed['phase_history'].map{|row|row['candidate']['schedule_id']},'History lost stable phase IDs')
  assert_equal([8,4],observed['phase_history'].map{|row|row['candidate'].dig('knockout','seeds')&.size},'History lost bracket sizes')
  workspace=Object.new
  workspace.define_singleton_method(:actor){'alpha'}
  overview_reads=0
  response=observed.merge('storage'=>'confirmed','results'=>reader.call(observed['candidate'],root).merge('schedule_id'=>observed['candidate']['schedule_id']))
  program.define_singleton_method(:ordinary_tournament_overview) do |*_,**|
    overview_reads+=1
    response
  end
  owner=T::Dialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
  driver=TournamentNativeDriver.new
  driver.step('Matches') do |form|
    phases=TournamentIndividualUI::F.field(form,'Tournament phase')
    assert_equal(['Quarterfinals','Semifinals','Final'],phases.options)
    assert_equal(2,phases.index)
    phases.index=0
    phases.trigger(:move)
  end
  driver.step('Matches') do |form|
    assert_equal('Matches — Quarterfinals; completed: 4/4',form.fields.first.options.first)
    phases=TournamentIndividualUI::F.field(form,'Tournament phase')
    phases.index=1
    phases.trigger(:move)
  end
  driver.step('Matches',[27]) do |form|
    assert_equal('Matches — Semifinals; completed: 2/2',form.fields.first.options.first)
  end
  T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
    publication:{'title'=>'Real compact history','__insertion_user'=>'alpha','publication_key'=>'history-ui'}).run
  driver.finish
  cached=response.reject{|key,_|key=='storage'}
  program.class.define_singleton_method(:tournament_view_snapshot){|_|cached}
  screen=T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,mode: :results,
    publication:{'title'=>'Real compact history','__insertion_user'=>'alpha','publication_key'=>'history-ui'})
  driver=TournamentNativeDriver.new
  driver.step('Results — Final',[27]) do |form|
    reads=overview_reads
    screen.send(:refresh_schedule,automatic:true)
    assert_equal(reads,overview_reads,'Automatic results refresh repeated coordinator reads')
    screen.send(:refresh_schedule)
    assert_equal(reads+1,overview_reads,'Manual Refresh used a retained projection')
    cached=cached.merge('candidate'=>cached['candidate'].merge('schedule_id'=>'f'*64))
    screen.send(:refresh_schedule,automatic:true)
    assert_equal(reads+2,overview_reads,'Another phase bypassed plan validation')
    cached=response.reject{|key,_|key=='storage'}
    screen.instance_variable_set(:@mode,:matches)
    assert_equal(nil,screen.send(:coordinated_view),'Organizer native match controls reused standings-only data')
    screen.instance_variable_set(:@mode,:results)
  end
  screen.run
  driver.finish
ensure
  program.class.singleton_class.remove_method(:tournament_view_snapshot) if program.class.respond_to?(:tournament_view_snapshot)
  program.finalize
  program.class.app_runtime.close
end
puts 'PASS actual phase archive to native UI: unique phase IDs, bracket names, current phase and historical completed matches'
