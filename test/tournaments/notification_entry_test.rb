require_relative '../support/settings_widget'
require_relative '../support/app_notification_models'
T=GameRoomTournaments
metadata={'publication_ref'=>{'author'=>'bob','publication_key'=>'fixture'},'match_id'=>'b'*64,'leg'=>1,'token'=>'c'*64}
notice=Programs::AppNotification.new(id:1,app_uuid:EltenGameRoom.server_app_uuid,
  type:T::ProposalNotice::TYPE,sender:'Bob',created_at:100,metadata:metadata)
app=EltenGameRoom.new
assert(app.notification_action(T::ProposalNotice::ACTION,notice)==false,'Old proposal invoked a removed entry point')
presentation=EltenGameRoom.map_notification(notice)
assert(presentation.action.nil? && presentation.default_suppressed?,'Old proposal still allows acceptance')
assert(!EltenGameRoom.respond_to?(:tournament_pending_invitations),'A second invitation inbox is still active')
assert(GameRoomSingleInstance.active_program.nil?,'Ignored old notification retained UI ownership')
puts 'PASS obsolete tournament invitation rejected; ordinary invitation entry remains the only active route'
