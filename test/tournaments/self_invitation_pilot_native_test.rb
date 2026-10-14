require_relative '../support/tournament_individual_ui'
require_relative '../support/proposal_notice_storage'
require_relative '../../lib/tournaments/proposal_notice_journal'
require_relative '../../tools/tournaments/self_invitation_pilot'
include GameRoomTest::Assertions
fixture=TournamentIndividualUI.fixture
program=fixture[:program]
klass=program.class
klass.include(TournamentSelfInvitationPilot)
namespace=Module.new
namespace.const_set(:GameRoomTournaments,GameRoomTournaments)
namespace.const_set(:GameRoomUI,GameRoomUI)
namespace.const_set(:GameRoomContent,GameRoomContent)
directory=program.data_path
storage=ProposalNoticeStorageSupport::Program.new(directory)
now=100
account='guliwer'
klass.define_singleton_method(:self_test_namespace){namespace}
klass.define_singleton_method(:self_test_now){now}
klass.define_singleton_method(:self_test_account){account}
klass.define_singleton_method(:data_path){|name|storage.data_path(name)}
klass.define_singleton_method(:update_json){|name,**options,&edit|storage.update_json(name,**options,&edit)}
klass.define_singleton_method(:server_app_uuid){'5e914c62-0fae-4fb1-a36c-544b299513ea'}
notices=[]
thread=Thread.current
program.define_singleton_method(:alert){|message|raise 'Worker alert' unless Thread.current==thread;notices<<message}
Presentation=Struct.new(:title,:body,:sound,:action,:suppressed,keyword_init:true) do
  def suppress_default!;self.suppressed=true;self;end
end
Notification=Struct.new(:type,:app_uuid,:sender,:metadata,keyword_init:true) do
  def presentation(**options);Presentation.new(**options);end
end
notification=Notification.new(type:TournamentSelfInvitationPilot::TYPE,app_uuid:klass.server_app_uuid,sender:'guliwer',
  metadata:{'token'=>'a'*64,'tournament_id'=>7})
record={'title'=>'Próba zaproszenia — szachy','recipient'=>'guliwer','token'=>'a'*64,'tournament_id'=>7,
  'players'=>['guliwer','Wirtualny gracz testowy'],'expires_at'=>1000,'answer'=>nil,'delivery'=>'confirmed'}
begin
  %w[accept decline back].each do |answer|
    File.binwrite(klass.data_path(TournamentSelfInvitationPilot::FILE),JSON.generate({'version'=>1,'invite'=>record}))
    presentation=klass.map_notification(notification)
    assert_equal(TournamentSelfInvitationPilot::ACTION,presentation.action)
    driver=TournamentNativeDriver.new
    driver.step('Zaproszenie do turnieju — test',[]) do |form|
      assert_equal(nil,form.accept_button,'Enter on details accepts automatically')
      assert_equal(['Zagraj','Nie teraz','Wstecz'],form.fields.drop(1).map(&:label))
      form.index=answer=='accept' ? 1 : answer=='decline' ? 2 : 3
      form.focus
    end
    driver.step('Zaproszenie do turnieju — test',[13]){}
    assert_equal(true,program.notification_action(TournamentSelfInvitationPilot::ACTION,notification))
    driver.finish
    stored=JSON.parse(File.binread(klass.data_path(TournamentSelfInvitationPilot::FILE)))['invite']
    assert_equal(answer=='back' ? nil : answer,stored['answer'])
    assert_equal(false,program.notification_action(TournamentSelfInvitationPilot::ACTION,notification)) unless answer=='back'
  end
  account='other'
  assert(klass.map_notification(notification).suppressed,'Wrong account received a playable self invitation')
  account='guliwer'
  now=1000
  assert(klass.map_notification(notification).suppressed,'Expired self invitation still actionable')
  now=100
  notification.sender='other'
  assert(klass.map_notification(notification).suppressed,'Forged sender invitation still actionable')
  assert_equal(2,notices.size)
  assert_equal(0,klass.app_runtime.managed_resources.size)
ensure
  program.finalize
  klass.app_runtime.close
end
puts 'PASS own-account native invitation pilot: Play/Not now/Back, explicit choice, single stored answer, account/sender/expiry guards, owner-thread confirmation, clean resources'
