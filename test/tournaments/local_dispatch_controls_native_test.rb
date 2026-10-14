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
require_relative '../../lib/tournaments/local_dispatch_screen'
include GameRoomTest::Assertions
class ProposalControlsBase
  attr_reader :last_action
  def additional_game_fields; []; end
  def text(value);GameRoomContent.utf8(value);end
  def button(label,&block);control=Button.new(text(label));control.on(:press,&block);control;end
  def start_fixed(action,**options);@last_action=[action,options];end
end
class ProposalControls < ProposalControlsBase
  prepend GameRoomTournaments::LocalDispatchScreen
end
fixture=TournamentIndividualUI.fixture
driver=TournamentNativeDriver.new
begin
  %w[en pl ru].each do |language|
    GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
    model=ProposalControls.new
    workspace=Object.new;workspace.define_singleton_method(:actor){'guliwer'}
    model.instance_variable_set(:@workspace,workspace)
    fields=model.send(:additional_game_fields)
    form=GameRoomUI::Form.new(fields,program:fixture[:program],quiet:true)
    model.instance_variable_set(:@form,form)
    visible=->(name){control=model.instance_variable_get("@dispatch_#{name}");form.instance_variable_get(:@hidden)[form.fields.index(control)]!=true}
    snapshot={'active'=>[],'candidates'=>[],'own_ready'=>false,'proposal'=>nil,'max_tables'=>3}
    present=->(value){model.instance_variable_set(:@dispatch_status,{state: :awaiting_consent,status:value});model.send(:update_dispatch_controls)}
    present.call(snapshot)
    assert(visible.call('ready'),'Initial Ready missing')
    %w[play decline return not_now withdraw renew].each{|name|assert(!visible.call(name),"Initial #{name} visible")}
    proposal={'token'=>'a'*64,'players'=>%w[guliwer beta],'leg'=>1,'accepted'=>[]}
    present.call(snapshot.merge('own_ready'=>true,'proposal'=>proposal))
    assert(visible.call('play') && visible.call('decline') && !visible.call('ready'),'Normal proposal controls wrong')
    assert_equal(GameRoomContent.utf8(GameRoomLocalization.translate('Not now')),model.instance_variable_get(:@dispatch_decline).label,'Normal match still says Decline')
    model.instance_variable_set(:@dispatch_status,{state: :awaiting_consent,status:snapshot.merge('proposal'=>proposal.merge('token'=>'b'*64))})
    model.instance_variable_get(:@dispatch_play).trigger(:press)
    assert_equal('a'*64,model.last_action.last[:proposal_token],'Click accepted an unseen changed proposal')
    controller=Struct.new(:view).new({selected_id:'another-plan'})
    model.instance_variable_set(:@controller,controller)
    present.call(snapshot.merge('intent_id'=>'old-plan','own_ready'=>true,'proposal'=>proposal))
    assert(!visible.call('play') && model.instance_variable_get(:@displayed_proposal_token).nil?,'Old plan proposal remained actionable')
    model.instance_variable_set(:@controller,nil)
    present.call(snapshot.merge('own_ready'=>true,'proposal'=>proposal.merge('leg'=>2)))
    assert(visible.call('return') && visible.call('not_now') && !visible.call('play') && !visible.call('decline'),'Return controls wrong')
    present.call(snapshot.merge('own_ready'=>true,'proposal'=>proposal.merge('leg'=>2,'accepted'=>['guliwer'])))
    assert(!visible.call('return') && visible.call('not_now'),'Accepted return can be accepted twice')
    present.call(snapshot.merge('own_ready'=>true,'active'=>[{'players'=>%w[guliwer beta],'bound'=>true,'started'=>true}]))
    assert(!visible.call('play') && !visible.call('ready') && !visible.call('return'),'Game received another play proposal')
    present.call(snapshot)
    assert(visible.call('ready'),'Refused/expired player cannot become ready')
    form.index=form.fields.index(model.instance_variable_get(:@dispatch_ready));form.focus
  end
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native EN/PL/RU proposal controls: initial opt-in, normal/return choices, accepted/playing states and displayed-token capture'
