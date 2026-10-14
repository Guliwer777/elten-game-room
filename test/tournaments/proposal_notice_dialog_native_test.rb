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
require_relative '../../lib/tournaments/proposal_notice_dialog'
include GameRoomTest::Assertions
T=GameRoomTournaments
fixture=TournamentIndividualUI.fixture
scope={'account'=>'alice','account_epoch'=>'epoch-1','backend_identity'=>'trial'}
notice={'version'=>1,'backend_identity'=>'trial','publication_ref'=>{'author'=>'owner','publication_key'=>'fixture'},
  'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1,'token'=>'c'*64,'recipient'=>'alice'}
proof={'status'=>'confirmed','metadata'=>notice,'players'=>%w[alice bob],'accepted'=>[],'sender'=>'owner',
  'ready'=>%w[alice bob].to_h{|name|[name,{'state'=>'ready','revision'=>'ready-1'}]},'revision'=>'proposal-1','window'=>{'opens'=>100,'closes'=>200}}
answers=[]
backend=Object.new
backend.define_singleton_method(:lookup_proposal){|notice:|proof}
backend.define_singleton_method(:respond_proposal){|**args|answers << args; :confirmed}
service=T::ProposalNotice.new(backend:backend,context:-> {scope},clock:-> {150})
begin
  %w[en cs es pl ru].each do |language|
    GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
    l=->(text){GameRoomContent.utf8(GameRoomLocalization.translate(text))}
    [1,2].each do |leg|
      notice['leg']=leg
      proof['accepted']=[]
      driver=TournamentNativeDriver.new
      driver.step(l.call('Game invitation'),[13]) do |form|
        assert_equal(nil,form.accept_button,'Enter on details must not auto-accept')
        assert_equal('alice — bob',form.fields.first.text.split(': ').last)
        expected=leg==2 ? ['Return match','Not now','Back'] : ['Play','Not now','Back']
        assert_equal(expected.map(&l),form.fields.grep(Button).map(&:label))
        assert_equal(0,answers.size)
      end
      driver.step(l.call('Game invitation'),[]) do |form|
        assert_equal(0,answers.size)
        form.index=2
        form.focus
      end
      driver.step(l.call('Game invitation'),[13]){}
      T::ProposalNoticeDialog.new(program:fixture[:program],service:service,metadata:notice,sender:'owner',work:->(&operation){operation.call}).run
      driver.finish
      assert_equal(false,answers.pop[:accept])
    end
  end
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native proposal dialog EN/CS/ES/PL/RU: explicit Play/Not now, Return/Not now, no Enter consent and closed resources'
