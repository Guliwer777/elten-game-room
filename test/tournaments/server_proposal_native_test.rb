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
  fixture=TournamentIndividualUI.fixture
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  l=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
  workspace=Object.new
  workspace.define_singleton_method(:actor){'Alice'}
  owner=T::LocalTestDialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
  calls=[]
  result={'state'=>'missing','token'=>nil,'players'=>%w[alice bob],'accepted'=>[],'declined'=>[],
    'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false}
  workspace.define_singleton_method(:shared_proposal) do |action:,token:,context:,lease:,**|
    raise 'Stale pilot screen' unless context.current?(lease)
    calls<<[action,token]
    case action
    when 'propose' then result=result.merge('state'=>'awaiting_consent','token'=>'a'*64)
    when 'accept'
      raise 'Displayed token not retained' unless token=='a'*64
      result=result.merge('accepted'=>['alice'])
    when 'decline' then result=result.merge('state'=>'declined','declined'=>['alice'])
    end
    result
  end
  driver=TournamentNativeDriver.new
  header=l.call('Shared match proposal (server test)')
  driver.step(header,[13]) do |form|
    assert_equal([['read',nil]],calls,'Opening or Enter on details accepted a match')
    assert_equal(nil,form.accept_button,'Details Enter is bound to consent')
    form.index=1
    form.focus
  end
  driver.step(header,[]) do |form|
    assert_equal([['read',nil],['propose',nil]],calls)
    assert_equal(l.call('Return match'),form.fields[2].label)
    assert_equal(l.call('Not now'),form.fields[3].label)
    form.index=2
    form.focus
  end
  driver.step(header,[13]){}
  driver.step(header,[]) do |form|
    assert_equal('accept',calls.last[0])
    assert(form.fields[0].text.include?('alice'),'Accepted player missing')
    form.index=3
    form.focus
  end
  driver.step(header,[13]){}
  driver.step(header,[27]) do |form|
    assert_equal('decline',calls.last[0])
    assert(form.fields[0].text.include?(l.call('The proposal was declined. The match remains pending.')),'Not now lost pending fixture explanation')
  end
  begin
    T::ServerProposalScreen.new(program:fixture[:program],workspace:workspace,owner:owner,
      publication:{'__insertion_user'=>'Alice','publication_key'=>'fixture'},match:{'match_id'=>'b'*64,'leg'=>2,'players'=>%w[bob alice]}).run
    driver.finish
    assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
  ensure
    fixture[:program].finalize
    fixture[:program].class.app_runtime.close
  end
end
puts 'PASS native pilot proposals EN/PL/CS/ES/RU: explicit proposal and return consent, no automatic Enter acceptance, retained token, Not now keeps fixture pending, clean resources'
