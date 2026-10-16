require_relative '../support/widget_presets'

app=EltenGameRoom.allocate
calls=[]
app.define_singleton_method(:initialize_services){calls<<:initialize}
app.define_singleton_method(:show_tournaments){|mine:|calls<<[:show,mine]}
app.send(:show_my_tournaments)
assert(calls==[:initialize,[:show,true]],'Quick access did not select own tournaments')
assert(!app.instance_variable_get(:@showing_my_tournaments),'Quick access remained locked')

app.instance_variable_set(:@showing_my_tournaments,true)
table=GameRoomUI::Form.new([])
dashboard=GameRoomUI::Form.new([])
app.instance_variable_set(:@table_network_view,{layout:Struct.new(:form).new(table)})
calls.clear
$activecontrols=[table,dashboard]
app.send(:show_my_tournaments)
assert(calls.empty?,'Repeated shortcut nested another tournament dashboard')
$activecontrols=[table]
app.send(:show_my_tournaments)
assert(calls==[:initialize,[:show,true]],'A tournament table could not reopen its tournament')
assert(app.instance_variable_get(:@showing_my_tournaments),'Nested quick access cleared its parent guard')
app.define_singleton_method(:show_tournaments){|**|raise IOError,'test'}
begin
  app.send(:show_my_tournaments)
  raise 'Error swallowed'
rescue IOError
  assert(app.instance_variable_get(:@showing_my_tournaments),'Error lost the parent guard')
ensure
  $activecontrols=[]
end
puts 'PASS tournament quick access: own filter, no recursive dashboard, table reentry and error cleanup'
