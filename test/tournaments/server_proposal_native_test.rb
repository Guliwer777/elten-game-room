if ARGV.first
  previous=ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS']=previous
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_proposal_screen'
include GameRoomTest::Assertions
T=GameRoomTournaments
%w[en pl cs es ru].each do |language|
  [:invite,:accept,:observe,:stale,:open].each do |scenario|
    fixture=TournamentIndividualUI.fixture
    GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
    l=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
    workspace=Object.new
    workspace.define_singleton_method(:actor){'Alice'}
    alerts=[]
    owner=T::Dialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){alerts<<message})
    calls,opened=[],[]
    result={'state'=>'awaiting_consent','token'=>'a'*64,'players'=>%w[alice bob],'accepted'=>['bob'],'declined'=>[],
      'window'=>{'opens'=>1,'closes'=>Time.now.to_i+300}}
    result=result.merge('state'=>'missing','token'=>nil,'accepted'=>[]) if scenario==:invite
    workspace.define_singleton_method(:shared_proposal) do |action:,token:,context:,lease:,**|
      raise 'Stale screen' unless context.current?(lease)
      calls<<[action,token]
      case action
      when 'propose' then result=result.merge('state'=>'awaiting_consent','token'=>'a'*64,'accepted'=>['alice'])
      when 'accept'
        raise 'Displayed token not retained' unless token=='a'*64
        result=result.merge('state'=>'consented','accepted'=>%w[alice bob])
      when 'decline' then result=result.merge('state'=>'declined','accepted'=>result['accepted']-['alice'],'declined'=>['alice'])
      end
      result
    end
    fixture[:program].define_singleton_method(:open_ordinary_tournament_match){|*args|opened<<args}
    screen=T::ServerProposalScreen.new(program:fixture[:program],workspace:workspace,owner:owner,
      publication:{'__insertion_user'=>'Alice','publication_key'=>'fixture'},
      match:{'match_id'=>'b'*64,'leg'=>2,'players'=>%w[alice bob]},
      play:[:accept,:stale,:open].include?(scenario),expected_token:scenario==:stale ? 'c'*64 : nil)
    driver=TournamentNativeDriver.new
    unless scenario==:stale
      driver.step(l.call('Tournament match'),[27]) do |form|
        case scenario
        when :invite
          assert_equal([['read',nil]],calls,'Viewing a match sent an invitation')
          form.accept_button.trigger(:press)
          assert_equal('propose',calls.last.first)
          assert(form.fields[0].text.include?('bob'),'Waiting names are missing')
          assert_equal(['alice'],screen.instance_variable_get(:@observed)['accepted'])
        when :accept,:open
          assert_equal([['read',nil],['accept','a'*64]],calls,'One Play did not accept exactly once')
          if scenario==:open
            screen.send(:update_invitation)
            assert_equal(1,opened.size,'Consented creator did not enter automatically')
          end
        when :observe
          assert_equal([['read',nil]],calls,'Viewing a notice recorded consent')
        end
      end
    end
    begin
      screen.run
      driver.finish
      if [:invite,:accept].include?(scenario)
        assert_equal('decline',calls.last.first,'Escape left pending consent')
      elsif scenario==:stale
        assert_equal([['read',nil]],calls,'Old notification accepted a newer invitation')
        assert_equal([l.call('This match invitation is no longer available.')],alerts)
      end
      assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
    ensure
      fixture[:program].finalize
      fixture[:program].class.app_runtime.close
    end
  end
end
puts 'PASS native invitations in five languages: read-only viewing, one Play, automatic entry, Escape cancellation and stale notification'
