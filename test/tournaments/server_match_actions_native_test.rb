if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/assertions'
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/server_schedule_overview'
require EltenTestHost.file('src/ui/controls/menu.rb')
include GameRoomTest::Assertions
T=GameRoomTournaments

# Only the menu catalogue is isolated. The host's keyprocs dispatches the real
# Ctrl+letter binding against the production context menu and native key state.
module GlobalMenu
  class << self
    attr_accessor :control
    def opened?; false; end
    def ctitems
      menu=EltenAPI::Controls.const_get(:Menu).new
      control.context(menu,false) if control
      menu.items
    end
  end
end
class MatchShortcutDriver < TournamentNativeDriver
  def tick(form)
    super
    return unless form.is_a?(GameRoomUI::Form) && form.instance_variable_get(:@wait)
    GlobalMenu.control=form.fields[form.index]
    keyprocs
  end
end

%w[en pl cs es ru].each do |language|
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  l=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
  if language!='en'
    ['Do you want to play this match?','This match has already been played.'].each do |message|
      assert(l.call(message)!=message,"#{language}: new match message is untranslated")
    end
  end
  program=TournamentEntryContextTest::Program.new
  alerts,confirmations,actions=[],[],[]
  answer=false
  after_confirm=nil
  owner=T::Dialogs::Owner.new(-> {'alpha'},->(message){alerts<<message})
  workspace=Object.new
  workspace.define_singleton_method(:actor){'alpha'}
  own={'match_id'=>'own','number'=>7,'leg'=>1,'players'=>%w[alpha beta]}
  other={'match_id'=>'other','number'=>8,'leg'=>1,'players'=>%w[beta gamma]}
  done={'match_id'=>'done','number'=>9,'leg'=>1,'players'=>%w[alpha gamma]}
  candidate={'format'=>'round_robin','schedule_id'=>'current','matches'=>[done,own,other]}
  results={'results'=>[done.slice('match_id','leg').merge('summary'=>{'draw'=>true,'winners'=>[]})],
    'standings'=>[], 'forfeitable_matches'=>[own], 'cancellable_matches'=>[other]}
  program.define_singleton_method(:ordinary_tournament_overview){|*_,**|{'candidate'=>candidate,'storage'=>'confirmed','results'=>results}}
  program.define_singleton_method(:open_ordinary_tournament_match){|publication,match|actions<<[:play,publication,match]}
  program.define_singleton_method(:award_ordinary_tournament_forfeit){|*args,**options|actions<<[:forfeit,args,options]}
  # Confirmation is supplied by the host, not implemented by this screen.
  program.define_singleton_method(:confirm) do |prompt|
    confirmations<<prompt
    after_confirm&.call
    answer
  end
  screen=T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
    publication:{'title'=>'Actions','__insertion_user'=>'alpha','publication_key'=>'actions'})
  driver=MatchShortcutDriver.new
  driver.step(l.call('Matches'),[13]) do |form|
    GlobalMenu.control=form.fields.first
    assert(GlobalMenu.ctitems.empty?,'Summary has match actions')
  end
  driver.step(l.call('Matches'))
  driver.step(l.call('Matches'),[13]) do |form|
    assert(confirmations.empty? && actions.empty?,'Enter on summary performed a match action')
    form.fields.first.index=1
    GlobalMenu.control=form.fields.first
    assert_equal([[l.call('Play'),'g'],[l.call('Award forfeit'),'f']],GlobalMenu.ctitems.map{|item|[item[0],item[3]]})
  end
  driver.step(l.call('Matches')) do
    assert_equal([l.call('Do you want to play this match?')],confirmations)
    assert(actions.empty?,'Declining Play sent a request')
  end
  driver.step(l.call('Matches'),[17,71]){answer=true}
  driver.step(l.call('Matches')) do |form|
    assert_equal(2,confirmations.size,'Ctrl+G did not ask for confirmation exactly once')
    assert_equal([:play],actions.map(&:first),'Ctrl+G did not open the ordinary table exactly once')
    form.fields.first.index=3
  end
  driver.step(l.call('Matches'),[13])
  driver.step(l.call('Matches')) do |form|
    assert_equal([l.call('This match has already been played.')],alerts)
    assert_equal(2,confirmations.size,'Completed match asked to play')
    GlobalMenu.control=form.fields.first
    assert_equal([[l.call('Match result'),'w']],GlobalMenu.ctitems.map{|item|[item[0],item[3]]})
  end
  driver.step(l.call('Matches'),[17,87])
  driver.step(l.call('Match result'),[27]){|form|assert_equal(l.call('Draw'),form.fields.first.text)}
  driver.step(l.call('Matches')){|form|form.fields.first.index=1}
  driver.step(l.call('Matches'),[17,70])
  driver.step(l.call('Winner by forfeit'),[27])
  driver.step(l.call('Matches')) do |form|
    assert(!actions.any?{|item|item.first==:forfeit},'Cancelling the forfeit recorded a result')
    form.fields.first.index=2
    GlobalMenu.control=form.fields.first
    assert_equal([[l.call('Cancel tournament match and award forfeit'),'F']],GlobalMenu.ctitems.map{|item|[item[0],item[3]]})
  end
  driver.step(l.call('Matches'),[17,16,70])
  driver.step(l.call('Cancelling the tournament match'),[27])
  driver.step(l.call('Matches')) do |form|
    form.fields.first.index=1
    after_confirm=-> {screen.instance_variable_set(:@current_schedule_id,'new-phase')}
  end
  driver.step(l.call('Matches'),[13])
  driver.step(l.call('Matches'),[27]) do
    assert_equal(3,confirmations.size)
    assert_equal([:play],actions.map(&:first),'A phase change during confirmation opened a stale match')
    assert_equal([l.call('This match has already been played.')],alerts)
  end
  begin
    screen.run
    driver.finish
  ensure
    GlobalMenu.control=nil
    program.finalize
    program.class.app_runtime.close
  end
end
puts 'PASS match actions in five languages: summary, Enter, Ctrl+G/W/F/Shift+F, decline, completed notice and stale confirmation'
