require_relative '../support/widget_presets'
require_relative '../support/assertions'
include GameRoomTest::Assertions
calls=[]
program=Object.new
program.define_singleton_method(:show_my_tournaments) {calls << :mine}
program.define_singleton_method(:show_tournaments) {calls << :all}
form=GameRoomUI::Form.new([],program:program)
form.game_room_tournament_shortcut_enabled=true
form.send(:open_tournaments)
form.send(:open_my_tournaments)
assert_equal([:all,:mine],calls)
form.game_room_tournament_shortcut_enabled=false
form.send(:open_tournaments)
assert_equal(2,calls.size,'Tournament browser available outside lobby')
active=true
widget=nil
widget=GameRoomWidget::TableList.new(loader:-> {[]},opener:->(*) {},labeler:->(*) {},id_for:->(*) {},
  active:-> {active},worker:WidgetManualWorker.new,tournament_browser:-> {calls << :widget_all;widget.send(:open_tournament_browser)},
  tournaments:-> {calls << :widget_mine})
menu=FakeMenu.new
widget.context(menu,false)
all=menu.options.find { |item|item.first=='Tournaments' }
mine=menu.options.find { |item|item.first=='My tournaments' }
assert(all && all[2]=='t','Ctrl+T context entry missing')
assert(mine && mine[2]=='T','Ctrl+Shift+T context entry missing')
all.last.call
mine.last.call
assert_equal([:all,:mine,:widget_all,:widget_mine],calls,'Reentrant widget entry repeated')
active=false
widget.send(:open_tournament_browser)
assert_equal(4,calls.size,'Off-widget browser action active')
puts 'PASS tournament entry callbacks: lobby-only browser, separate all/mine widget actions, context accelerators and reentry guards; no keyboard injection'
