require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/settings_widget'
require_relative '../support/app_notification_models'
require_relative '../support/tournament_public_ui'
T=GameRoomTournaments
runtime=TestTaskRuntime.new('start-notice-runtime')
EltenGameRoom.define_singleton_method(:app_runtime){runtime}
module Programs
  class << self
    attr_accessor :notice_runtime
    def notification_program(_uuid);EltenGameRoom;end
    def runtime_for(_program);notice_runtime;end
  end
end
Programs.notice_runtime=runtime
module EltenAPI::NotificationService
  class << self
    attr_accessor :rows
    def active_notifications;rows || [];end
  end
end
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
scope={'account'=>'alice','account_epoch'=>'epoch-one','backend_identity'=>'trial'}
now=Time.utc(2026,10,15,18).to_i
publications=[11,12,13].map{|id|TournamentPublicUI.publication(id).merge('__insertion_user'=>'Alice','timezone'=>'UTC')}
reads=[]
source=->(reference){reads<<[Thread.current,Programs.current_runtime];
  {'complete'=>true,'participants'=>%w[alice bob],'publication'=>publications.find{|row|row['publication_key']==reference['publication_key']}}}
notices=publications.map do |publication|
  reference={'author'=>'alice','publication_key'=>publication['publication_key']}
  T::TournamentStartNotice.metadata({'version'=>1,'backend_identity'=>'trial','publication_ref'=>reference,'recipient'=>'alice',
    'event_id'=>Digest::SHA256.hexdigest(JSON.generate(['tournament-start-v1','trial',reference]))})
end
uuid=EltenGameRoom.server_app_uuid
make_row=->(id,notice){Struct.new(:id,:cat,:app_uuid,:date,:revoked,:payload,:alert,keyword_init:true).new(id:id,cat:'app',app_uuid:uuid,
  date:now,revoked:false,alert:'',payload:{'sender'=>'Alice','type'=>T::TournamentStartNotice::TYPE,'metadata'=>notice})}
rows=notices.each_with_index.map{|notice,index|make_row.call(index+1,notice)}
EltenAPI::NotificationService.rows=rows
EltenGameRoom.define_singleton_method(:normalized_settings){EltenGameRoom::DEFAULT_SETTINGS.merge('invitation_notifications'=>'nobody','invitation_sounds'=>false)}
events=[]
$notifications_callback=->(event){events<<event}
begin
  assert(Programs.receive_app_notification(rows[0]).last.default_suppressed?,'Disconnected start reader exposed metadata')
  EltenGameRoom.configure_tournament_starts(source:source,context:-> {scope},clock:-> {now},registry:GameRoomGames::CATALOG)
  EltenGameRoom.with_tournament_area do
    EltenGameRoom.with_tournament_area do
      assert(EltenGameRoom.inside_tournament_area?,'Nested tournament area was lost')
      assert(Programs.receive_app_notification(rows[0]).last.default_suppressed?,'Start announced inside tournaments')
      EltenGameRoom.tournament_proposals_tick
    end
    assert(EltenGameRoom.inside_tournament_area?,'Nested return cleared the outer tournament area')
  end
  assert(!EltenGameRoom.inside_tournament_area?,'Tournament area remained active after exit')
  Programs.receive_app_notification(rows[0])
  duplicate=make_row.call(99,notices[0])
  assert(Programs.receive_app_notification(duplicate).last.default_suppressed?,'Same start resurfaced under another notification ID')
  EltenGameRoom.tournament_proposals_tick
  assert(reads.empty? && events.empty?,'Muted start queried or announced after exit')
  Programs.receive_app_notification(rows[1])
  EltenGameRoom.tournament_proposals_tick
  worker=EltenGameRoom.instance_variable_get(:@tournament_start_inbox).instance_variable_get(:@worker)
  wait_background_work(worker) or raise 'Start verification did not finish'
  EltenGameRoom.tournament_proposals_tick
  assert(events.size==1 && events[0]['type']==T::TournamentStartNotice::TYPE,'Outside start not presented')
  assert(events[0]['alert'].include?(publications[1]['title']),'Real tournament title missing')
  assert(events[0]['sound'].nil?,'Sound preference ignored')
  assert(reads.first[0]!=Thread.current && reads.first[1]==runtime,'Verification ran on UI or wrong runtime')
  Programs.receive_app_notification(rows[2])
  EltenGameRoom.tournament_proposals_tick
  wait_background_work(worker) or raise 'Raced verification did not finish'
  EltenGameRoom.with_tournament_area{EltenGameRoom.tournament_proposals_tick}
  assert(Programs.map_app_notification(rows[2]).last.default_suppressed?,'Pending start resurfaced after leaving tournaments')
  10.times{EltenGameRoom.tournament_proposals_tick}
  assert_equal(1,events.size)
  assert_equal(2,reads.size)
  scope['account_epoch']='new-epoch'
  assert(Programs.map_app_notification(rows[1]).last.default_suppressed?,'Old account epoch stayed visible')
ensure
  EltenGameRoom.stop_tournament_proposals
  $notifications_callback=nil
  runtime.close
end
puts 'PASS native start-notice runtime: outside-only event, nested tournament area, permanent suppression after exit/duplicate ID, pending-job race, actual title/game, finite owning-runtime read, sound/epoch/cleanup guards and no polling'
