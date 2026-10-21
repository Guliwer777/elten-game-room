require_relative '../support/tournament_control_callbacks'
require EltenTestHost.file('src/ui/controls/grid_box.rb')
require_relative '../support/tournament_forfeit_native'
class Program
  def self.server_app(**_); end
  def self.app_runtime; nil; end
end
require_relative '../../__app'

class ForfeitConfirmationNativeApp < EltenGameRoom
  attr_reader :notices
  def initialize(service)
    @service=service
    @notices=[]
  end
  def ordinary_tournament_service(_publication); @service; end
  def run_network_task(*,**); yield; end
  def alert(message); @notices << message; end
end
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

def confirmation_button(form,label)
  form.fields.grep(Button).find { |button| button.label==label } || raise("Missing button: #{label}")
end

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentControlCallbacks.new
  before=f.documents.insert_count
  driver.step('Forfeit consequences') do |form|
    text=form.fields.first.text
    assert(text.include?('1. Alice; tournament points: 2') &&
      text.include?('2. Bob; tournament points: 0; Forfeit'),'Preview omitted final places or the forfeiter')
    assert_equal(before,f.documents.insert_count,'Opening confirmation wrote a result')
    confirmation_button(form,'Cancel').press
  end
  result=f.h.as('Alice') do
    app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'],names:{'alice'=>'Alice','bob'=>'Bob'})
  end
  driver.finish
  assert_equal(nil,result)
  assert_equal(before,f.documents.insert_count,'Cancellation published a result')
end

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentControlCallbacks.new
  after_creation=nil
  driver.step('Forfeit consequences') do |form|
    # Creating a waiting table changes the proof but does not start play.
    f.h.as('Alice') { f.services['Alice'].open_match(match_id:f.match['match_id'],leg:1) }
    after_creation=f.documents.insert_count
    confirmation_button(form,'Confirm result').press
  end
  driver.step('Forfeit consequences') do |form|
    assert_equal(after_creation,f.documents.insert_count,'Stale acceptance wrote before renewed consent')
    assert_equal(['The match changed. Review the updated consequences before confirming again.'],app.notices)
    confirmation_button(form,'Cancel').press
  end
  f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert_equal(after_creation,f.documents.insert_count,'Cancelling a fresh preview published the old decision')
  assert_equal([],f.services['Bob'].result_view['results'])
end

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentControlCallbacks.new
  driver.step('Forfeit consequences') { |form| confirmation_button(form,'Confirm result').press }
  result=f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  receipt=result && result['results'].first
  assert(receipt && receipt['kind']=='ordinary-match-forfeit-v3' &&
    receipt['summary']['forfeits']==['bob'],'Explicit confirmation failed to publish the administrative result')
  assert_equal([],app.notices)
end

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentControlCallbacks.new
  after_result=nil
  driver.step('Forfeit consequences') do |form|
    f.start
    12.times do
      replay=f.h.replay('Alice')
      break if replay.finished?
      f.h.submit(replay.current_player,f.h.game.legal_actions(replay,replay.current_player).first)
    end
    assert(f.h.replay('Alice').finished?,'Fixture failed to finish before confirmation')
    service=f.services['Alice']
    binding=service.send(:read_match_binding,f.candidate,5,f.match,nil)
    f.h.as('Alice') {service.collect([binding,f.candidate,5,f.match])}
    after_result=f.documents.insert_count
    confirmation_button(form,'Confirm result').press
  end
  f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert_equal(after_result,f.documents.insert_count,'Confirmation replaced the accepted normal result')
  assert_equal(['This match has already been resolved.'],app.notices)
  assert_equal('ordinary-match-result-v1',f.services['Bob'].result_view['results'].first['kind'])
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentControlCallbacks.new
  count=f.documents.insert_count
  f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert_equal(['This match is still being played. A manual forfeit cannot interrupt it.'],app.notices)
  assert_equal(count,f.documents.insert_count,'Active match was manually interrupted')
end

TournamentForfeitNative.with_fixture do |f|
  f.h.add_client('Organizer')
  f.candidate['publication_ref']['author']='organizer'
  f.services['Organizer']=f.make_service('Organizer')
  f.start
  app=ForfeitConfirmationNativeApp.new(f.services['Organizer'])
  count=f.documents.insert_count
  f.h.as('Organizer') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  assert_equal(['The current game history is unavailable. Join the table as an observer and try again. No forfeit was recorded.'],app.notices)
  assert_equal(count,f.documents.insert_count,'Missing history was treated as an unstarted match')
  assert(f.h.join('Organizer'),'Organizer could not join as an observer')
  f.h.as('Organizer') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  assert_equal('This match is still being played. A manual forfeit cannot interrupt it.',app.notices.last)
  assert_equal(count,f.documents.insert_count)
end
puts 'PASS native Program confirmation callbacks: complete consequences, cancel, v3 commit, fresh consent, normal result first and active-play denial; no keyboard'
