require_relative '../support/tournament_native'
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

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentNativeDriver.new
  before=f.documents.insert_count
  driver.step('Forfeit consequences',[27]) do |form|
    text=form.fields.first.text
    assert(text.include?('Bob loses by forfeit.') && text.include?('1. Alice; tournament points: 2') &&
      text.include?('2. Bob; tournament points: 0'),'Preview omitted losing participant or final tournament points')
    assert(text.include?('Forfeit before the match started.'),'Preview omitted the basis of settlement')
    assert_equal(before,f.documents.insert_count,'Opening confirmation wrote a result')
  end
  result=f.h.as('Alice') do
    app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'],names:{'alice'=>'Alice','bob'=>'Bob'})
  end
  driver.finish
  assert_equal(nil,result)
  assert_equal(before,f.documents.insert_count,'Escape published a forfeit')
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentNativeDriver.new
  before=f.documents.insert_count
  driver.step('Forfeit consequences',[13]) do |form|
    f.h.submit('Alice',f.h.game.legal_actions(f.h.replay('Alice'),'Alice').first)
    form.index=form.fields.index(form.fields.grep(Button).find { |button| button.label=='Confirm forfeit' })
  end
  driver.step('Forfeit consequences',[27]) do |_form|
    assert_equal(before,f.documents.insert_count,'Stale acceptance wrote before renewed consent')
    assert_equal(['The match changed. Review the updated consequences before confirming again.'],app.notices)
  end
  f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert_equal(before,f.documents.insert_count,'Cancelling second preview published the old decision')
end

TournamentForfeitNative.with_fixture do |f|
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentNativeDriver.new
  driver.step('Forfeit consequences',[13]) do |form|
    form.index=form.fields.index(form.fields.grep(Button).find { |button| button.label=='Confirm forfeit' })
  end
  result=f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert(result && result['results'].first['decision']['loser']=='bob','Explicit confirmation failed to publish')
  assert_equal([],app.notices)
end

TournamentForfeitNative.with_fixture do |f|
  f.start
  app=ForfeitConfirmationNativeApp.new(f.services['Alice'])
  driver=TournamentNativeDriver.new
  count=f.documents.insert_count
  driver.step('Forfeit consequences',[13]) do |form|
    12.times do
      replay=f.h.replay('Alice')
      break if replay.finished?
      actor=replay.current_player
      f.h.submit(actor,f.h.game.legal_actions(replay,actor).first)
    end
    assert(f.h.replay('Alice').finished?,'Fixture failed to finish before confirmation')
    form.index=form.fields.index(form.fields.grep(Button).find { |button| button.label=='Confirm forfeit' })
  end
  f.h.as('Alice') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
  assert_equal(count,f.documents.insert_count,'Confirmation replaced a normally finished result')
  assert_equal(['This match has already been resolved.'],app.notices)
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
  assert_equal(count,f.documents.insert_count,'Outside organizer wrote an unstarted forfeit')
  assert(f.h.join('Organizer'),'Organizer could not join normally as an observer')
  driver=TournamentNativeDriver.new
  driver.step('Forfeit consequences',[27]) do |form|
    assert(!form.fields.first.text.include?('before the match started'),'Observer got the unstarted consequences')
  end
  f.h.as('Organizer') {app.award_ordinary_tournament_forfeit({},f.match,'bob',f.candidate['schedule_id'])}
  driver.finish
end
puts 'PASS native app forfeit confirmation: readonly complete consequences, Escape/no writes, state change demands fresh consent, confirmed publication'
