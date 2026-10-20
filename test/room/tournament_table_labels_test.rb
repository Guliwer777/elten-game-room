require_relative '../support/settings_widget'
require_relative '../support/assertions'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
app=EltenGameRoom.new
lobby=Object.new
lobby.define_singleton_method(:owner_of){|row|row['owner']}
lobby.define_singleton_method(:capacity_of){|_|2}
app.instance_variable_set(:@lobby,lobby)
app.define_singleton_method(:game_definition){|_|nil}
app.define_singleton_method(:game_name){|_|'Axel Pong'}
app.define_singleton_method(:game_options_summary){|_|''}
app.define_singleton_method(:table_status_label){|_|'Waiting'}
app.define_singleton_method(:widget_table_available?){|_|true}
table={'name'=>'alice — peterman / 1 [0123456789ab]','owner'=>'Alice','game'=>'axel_pong',
  'tournament_match'=>{'match_id'=>'d'*64}}
snapshot=Struct.new(:table,:participant_count).new(table,2)
assert(app.send(:table_header,snapshot).include?('Tournament match'),'Users heading lacks tournament label')
assert(!app.send(:table_header,snapshot).include?('0123456789ab'),'Technical identity leaked into users heading')
assert(app.send(:table_join_label,snapshot).start_with?('Tournament match, '),'Open-table list lacks tournament label')
assert(app.send(:widget_table_label,snapshot).include?('Tournament match'),'Widget lacks tournament label')
assert_equal('alice — peterman / 1 [0123456789ab]',table['name'],'Display label rewrote the physical table identity')
ordinary=table.reject{|key,_|key=='tournament_match'}.merge('name'=>'Our table')
snapshot.table=ordinary
assert(app.send(:table_header,snapshot).include?('Our table'),'Ordinary table heading changed')
assert(!app.send(:table_join_label,snapshot).include?('Tournament match'),'Ordinary table labelled as tournament match')
puts 'PASS tournament display names in users heading, join list and widget; ordinary labels and physical names unchanged'
