require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_proposal_screen'
include GameRoomTest::Assertions
T=GameRoomTournaments

%w[en pl cs es ru].each do |language|
  fixture=TournamentIndividualUI.fixture
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  translate=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
  calls=[]
  workspace=Object.new
  workspace.define_singleton_method(:actor){'Bob'}
  value={'state'=>'awaiting_consent','token'=>'a'*64,'players'=>%w[alice bob],'accepted'=>['alice'],
    'window'=>{'opens'=>100,'closes'=>400},'table_available'=>false}
  workspace.define_singleton_method(:shared_proposal) do |**args|
    calls << args
    assert_equal('accept',args[:action],'Opening the verified invitation reread its display')
    assert_equal('a'*64,args[:token],'Acceptance lost its exact invitation token')
    value.merge('state'=>'consented','accepted'=>%w[alice bob])
  end
  reference={'author'=>'alice','publication_key'=>'fixture'}
  proof={'status'=>'confirmed','metadata'=>{'publication_ref'=>reference,'match_id'=>'b'*64,'leg'=>1,
    'token'=>'a'*64,'recipient'=>'bob'},'players'=>value['players'],'accepted'=>value['accepted'],'window'=>value['window']}
  owner=T::Dialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
  args={program:fixture[:program],workspace:workspace,owner:owner,
    publication:{'__insertion_user'=>'Alice','publication_key'=>'fixture'},match:{'match_id'=>'b'*64,'leg'=>1},
    clock:-> {100},play:true,expected_token:'a'*64,invitation_proof:proof}
  screen=T::ServerProposalScreen.new(**args)
  driver=TournamentNativeDriver.new
  driver.step(translate.call('Tournament match'),[27]) do |form|
    assert_equal(1,calls.size,'Acceptance was skipped or repeated')
    assert_equal('a'*64,screen.instance_variable_get(:@accepted_token))
    assert_equal(%w[alice bob],screen.instance_variable_get(:@observed)['accepted'])
    # This test is about opening/accepting. Leave without withdrawing consent.
    screen.instance_variable_set(:@accepted_token,nil)
  end
  begin
    screen.run
    driver.finish
    assert_equal(nil,screen.instance_variable_get(:@invitation_proof),'Observation retained after initial display')
    ['recipient','match_id','token'].each do |field|
      wrong=Marshal.load(Marshal.dump(proof));wrong['metadata'][field]='other'
      rejected=T::ServerProposalScreen.new(**args.merge(invitation_proof:wrong))
      assert_raises(ArgumentError){rejected.send(:invitation_view)}
    end
    accepted=proof.merge('accepted'=>%w[alice bob])
    assert_equal(nil,T::ServerProposalScreen.new(**args.merge(invitation_proof:accepted)).send(:invitation_view),
      'Already accepted invitation skipped the fresh native binding lookup')
    assert_equal(nil,T::ServerProposalScreen.new(**args.merge(clock:-> {400})).send(:invitation_view),
      'Expired observation was reused')
    failed=T::ServerProposalScreen.new(**args)
    workspace.define_singleton_method(:shared_proposal){|**a|calls<<a;nil}
    failure_driver=TournamentNativeDriver.new
    failure_driver.step(translate.call('Tournament match'),[27]) do |form|
      assert_equal(nil,failed.instance_variable_get(:@observed),'Failed fresh acceptance retained actionable observation')
      assert_equal(nil,failed.instance_variable_get(:@accepted_token),'Failed fresh acceptance inferred consent')
      assert(form.fields[0].text.include?(translate.call('The invitation could not be checked. Refresh before trying again.')),'Missing failed-acceptance explanation')
    end
    failed.run
    failure_driver.finish
  ensure
    fixture[:program].finalize
    fixture[:program].class.app_runtime.close
  end
end
puts 'PASS verified initial invitation display EN/PL/CS/ES/RU: no duplicate read, fresh acceptance, exact token/account/fixture, expiry, accepted-table fallback and failed acceptance'
