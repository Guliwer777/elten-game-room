require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/settings_widget'
require_relative '../support/app_notification_models'
T=GameRoomTournaments
runtime=TestTaskRuntime.new('tournament-notice')
EltenGameRoom.define_singleton_method(:app_runtime){runtime}
module Programs
  class << self
    attr_accessor :notice_runtime
    def notification_program(_uuid); EltenGameRoom; end
    def runtime_for(_program); notice_runtime; end
  end
end
Programs.notice_runtime=runtime
module EltenAPI::NotificationService
  class << self
    attr_accessor :rows
    def active_notifications; rows || []; end
  end
end
scope={'account'=>'alice','account_epoch'=>'epoch-1','backend_identity'=>'trial'}
notice={'version'=>1,'backend_identity'=>'trial','publication_ref'=>{'author'=>'owner','publication_key'=>'fixture'},
  'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1,'token'=>'c'*64,'recipient'=>'alice'}
proof={'status'=>'confirmed','metadata'=>notice,'players'=>%w[alice bob],'accepted'=>[],'sender'=>'owner',
  'ready'=>%w[alice bob].to_h{|name|[name,{'state'=>'ready','revision'=>'ready-1'}]},'revision'=>'proposal-1','window'=>{'opens'=>100,'closes'=>200}}
reads=[]
backend=Object.new
backend.define_singleton_method(:lookup_proposal){|notice:|reads << [Thread.current,Programs.current_runtime];proof}
backend.define_singleton_method(:respond_proposal){|**_args|raise 'Unexpected automatic consent'}
uuid=EltenGameRoom.server_app_uuid
row=Struct.new(:id,:cat,:app_uuid,:date,:revoked,:payload,:alert,keyword_init:true).new(
  id:1,cat:'app',app_uuid:uuid,date:150,revoked:false,alert:'',
  payload:{'sender'=>'owner','type'=>T::ProposalNotice::TYPE,'metadata'=>notice})
EltenAPI::NotificationService.rows=[row]
EltenGameRoom.define_singleton_method(:normalized_settings){EltenGameRoom::DEFAULT_SETTINGS.merge('invitation_notifications'=>'nobody','invitation_sounds'=>false)}
events=[]
$notifications_callback=->(event){events << event}
begin
  assert(Programs.receive_app_notification(row).last.default_suppressed?,'Missing authority must suppress a proposal')
  assert(reads.empty?,'Missing authority must not query the backend')
  EltenGameRoom.configure_tournament_proposals(backend:backend,context:-> {scope},clock:-> {150})
  presentation=Programs.receive_app_notification(row).last
  assert(presentation.default_suppressed? && presentation.action.nil?,'Unverified hint exposed an action')
  EltenGameRoom.tournament_proposals_tick
  worker=EltenGameRoom.instance_variable_get(:@tournament_proposal_inbox).instance_variable_get(:@worker)
  wait_background_work(worker) or raise 'Verification work did not finish'
  EltenGameRoom.tournament_proposals_tick
  assert(events.size==1 && events.first['type']==T::ProposalNotice::TYPE,'Verified global notice was lost')
  assert(events.first['sound'].nil?,'Saved sound preference ignored')
  assert(reads.first[0]!=Thread.current && reads.first[1]==runtime,'Backend read did not use finite native work')
  assert(Programs.map_app_notification(row).last.action==T::ProposalNotice::ACTION,'Verified proposal has no host action')
  30.times{EltenGameRoom.tournament_proposals_tick}
  Programs.receive_app_notification(row)
  EltenGameRoom.tournament_proposals_tick
  assert(events.size==1 && reads.size==1,'Idle update/redelivery repeated a read or announcement')
  # Unverified metadata and a changed authentication epoch never bypass filters.
  scope['account_epoch']='epoch-2'
  assert(Programs.map_app_notification(row).last.default_suppressed?,'Old-account verification stayed visible')
  assert(EltenGameRoom.normalized_settings['invitation_notifications']=='nobody','Ordinary invitation preference changed')
  # Sender-side composition invokes the SDK helper with a verified reference,
  # expiry and one durable attempt. Only the SDK/network boundary is replaced.
  EltenGameRoom.stop_tournament_proposals
  outgoing=notice.merge('recipient'=>'bob','token'=>'d'*64)
  proof['metadata']=outgoing
  proof['sender']='alice'
  EltenGameRoom.configure_tournament_proposals(backend:backend,context:-> {scope},clock:-> {150})
  deliveries=[]
  require 'tmpdir'
  delivery_directory=Dir.mktmpdir('notice-runtime-',ENV.fetch('TMPDIR'))
  EltenGameRoom.define_singleton_method(:data_path){|name|File.join(delivery_directory,name)}
  EltenGameRoom.define_singleton_method(:update_json) do |path,default:,&edit|
    filename=data_path(path)
    value=File.file?(filename) ? JSON.parse(File.binread(filename)) : Marshal.load(Marshal.dump(default))
    edit.call(value)
    File.binwrite(filename,JSON.generate(value))
  end
  EltenGameRoom.define_singleton_method(:send_notification) do |user,**options|
    deliveries << [user,options]
    true
  end
  assert(EltenGameRoom.send_tournament_proposal(outgoing)==:sent,'Verified SDK delivery not confirmed')
  assert(EltenGameRoom.send_tournament_proposal(outgoing)==:sent,'Confirmed duplicate changed state')
  assert(deliveries.size==1 && deliveries[0][0]=='bob' && deliveries[0][1][:type]==T::ProposalNotice::TYPE &&
    deliveries[0][1][:metadata]==T::ProposalNotice.metadata(outgoing) && deliveries[0][1][:expires_in]==50,'Wrong SDK recipient, metadata, expiry or duplicate')
ensure
  EltenGameRoom.stop_tournament_proposals
  $notifications_callback=nil
  runtime.close
end
puts 'PASS host proposal runtime: active-scene-independent native hooks, worker verification, guarded filter exception, saved sound setting, one announcement/read, epoch cleanup and no automatic consent'
