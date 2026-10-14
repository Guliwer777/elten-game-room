if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
include GameRoomTest::Assertions
I=TournamentIndividualUI
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
fixture=I.fixture
published=[]
def part_value(control,value)
  control.index=control.options.index(value)
  raise 'Requested date/time value missing' unless control.index
  control.trigger(:move)
end
def date_value(control,year,month,day)
  part_value(control,format('%04d',year))
  control.trigger(:key_right)
  part_value(control,format('%02d',month))
  control.trigger(:key_right)
  part_value(control,format('%02d',day))
end
def time_value(control,hour,minute)
  part_value(control,format('%02d',hour))
  control.trigger(:key_right)
  part_value(control,format('%02d',minute))
end
field=->(form,label){form.fields.find{|value|value.respond_to?(:header) && value.header.start_with?(label+': ')}}
driver=TournamentNativeDriver.new
driver.step('Game',[13]){|form|form.fields.first.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe')}
driver.step('Tournament name',[13]) do |form|
  I::F.field(form,'Tournament name').set_text('Weekend tournament')
  mode=I::F.field(form,'Tournament duration')
  assert_equal(['One day','Several days'],mode.options)
  mode.index=1
  mode.trigger(:move)
  date_value(field.call(form,'First tournament day'),2026,10,16)
  date_value(field.call(form,'Last tournament day'),2026,10,18)
  time_value(field.call(form,'Daily play starts'),19,0)
  time_value(field.call(form,'Daily play ends'),21,0)
  form.index=form.fields.index(form.accept_button)
end
editor=T::TournamentSetupEditor.new(program:fixture[:program],registry:GameRoomGames::CATALOG,configure:->(_game,options){options},
  clock:-> {Time.local(2026,10,13,15).to_i},alert:->(message){raise message},publish:->(**values){published<<values;{'status'=>'confirmed'}})
editor.wait
driver.finish
windows=published.first[:draft]['windows']
assert_equal(3,windows.size)
windows.each_with_index do |window,index|
  first=Time.at(T::LocalRegistrationTime.convert_utc(window['date'],window['start'])).getlocal
  last=Time.at(T::LocalRegistrationTime.convert_utc(window['end_date'],window['end'])).getlocal
  assert_equal("2026-10-#{16+index} 19:00",first.strftime('%Y-%m-%d %H:%M'))
  assert_equal("2026-10-#{16+index} 21:00",last.strftime('%Y-%m-%d %H:%M'))
end
publication=T::Publication.from_draft(**published.first,registry:GameRoomGames::CATALOG,publication_key:'native-weekend').to_row
driver=TournamentNativeDriver.new
driver.step('Tournament name',[27]) do |form|
  assert_equal(1,I::F.field(form,'Tournament duration').index,'Daily schedule did not reopen as several days')
  assert(field.call(form,'First tournament day').header.include?('2026-10-16'),'First local day changed on reopen')
  assert(field.call(form,'Last tournament day').header.include?('2026-10-18'),'Last local day changed on reopen')
  assert(field.call(form,'Daily play starts').header.include?('19:00'),'Daily local hour changed on reopen')
end
T::TournamentSetupEditor.new(program:fixture[:program],registry:GameRoomGames::CATALOG,configure:->(*){raise 'Edit requested game configuration'},
  publication:publication,alert:->(message){raise message},publish:->(**){raise 'Cancelled edit published'}).wait
driver.finish
legacy=publication.dup
continuous=T::LocalRegistrationTime.utc_window(Time.local(2026,10,16,19).to_i,Time.local(2026,10,18,21).to_i)
legacy['schedule_json']=JSON.generate({'windows'=>[continuous]})
legacy_saved=[]
driver=TournamentNativeDriver.new
driver.step('Tournament name',[13]) do |form|
  mode=I::F.field(form,'Tournament duration')
  assert_equal('Keep existing playing windows',mode.options[mode.index],'Continuous legacy window was silently changed to daily hours')
  form.index=form.fields.index(form.accept_button)
end
T::TournamentSetupEditor.new(program:fixture[:program],registry:GameRoomGames::CATALOG,configure:->(*){nil},publication:legacy,
  alert:->(message){raise message},publish:->(**values){legacy_saved<<values;{'status'=>'confirmed'}}).wait
driver.finish
assert_equal([continuous],legacy_saved.first[:draft]['windows'],'Editing a legacy continuous schedule removed overnight play')
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native daily setup: One day/Several days, date-only and time-only arrow editing, inclusive 16–18 October daily 19–21 UTC storage and correct reopened local schedule'
