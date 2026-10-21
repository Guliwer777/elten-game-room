require_relative '../support/session_runner'
require_relative '../../lib/table_activity_repository'
include GameRoomTest::Assertions
h=NativeRoomHarness.new(users:%w[Alice Bob])
host,guest=h.transports.values_at('Alice','Bob')
table=h.table
claim=h.as('Alice') {host.change_table_voice(table,{'operation'=>'claim','previous'=>''},actor:'Alice')}
assert_equal(true,claim[:accepted])
lost=h.as('Bob') {guest.change_table_voice(table,{'operation'=>'claim','previous'=>''},actor:'Bob')}
assert_equal(false,lost[:accepted])
assert_equal(claim[:voice],lost[:voice])
secret='not-public-test-password'
payload={'operation'=>'publish','previous'=>claim[:voice]['head'],'channel_id'=>31,'name'=>'Diagnostic conversation','password'=>secret}
forged=h.as('Bob') {guest.change_table_voice(table,payload,actor:'Bob')}
assert_equal(false,forged[:accepted])
published=h.as('Alice') {host.change_table_voice(table,payload,actor:'Alice')}
assert_equal(true,published[:accepted])
current=h.as('Bob') {guest.table_voice(table,force:true)}
assert_equal('ready',current['status'])
assert_equal(31,current['channel_id'])
assert_equal(secret,current['password'])
assert_equal(false,h.as('Alice') {host.change_table_voice(table,payload,actor:'Alice')}[:accepted])
entries=h.as('Bob') {guest.activity_records(table)}
assert_equal(1,entries.count { |entry|entry['kind']=='voice_started' })
assert(!JSON.generate(entries).include?(secret),'Password leaked into activity history')
assert(!JSON.generate(h.view('Alice').discovery_metadata).include?(secret),'Password leaked into discovery metadata')
assert(!JSON.generate(h.as('Bob') {guest.discover_rooms(include_private:true)}).include?(secret),
  'Membership-enriched browser rows exposed the voice password')
h.add_client('Carol')
assert(h.join('Carol'),'A late participant could not join the table')
late=h.transports.fetch('Carol')
assert_equal(current,h.as('Carol') {late.table_voice(table,force:true)},'A late arrival missed the current conference')
assert_equal(1,h.as('Carol') {late.activity_records(table).count { |entry|entry['kind']=='voice_started' }})
h.start
assert_equal(current,h.as('Bob') {guest.table_voice(table,force:true)},'Starting a game erased the conversation')
assert(h.as('Alice') {host.transfer_room_owner(table,'Bob')},'Could not transfer table ownership')
assert_equal(false,h.as('Carol') {late.change_table_voice(table,{'operation'=>'clear','previous'=>current['head']},actor:'Carol')}[:accepted])
cleared=h.as('Bob') {guest.change_table_voice(table,{'operation'=>'clear','previous'=>current['head']},actor:'Bob')}
assert_equal(true,cleared[:accepted])
assert_equal('none',h.as('Bob') {guest.table_voice(table,force:true)}['status'])

record=Struct.new(:packet,:sender,:message_id,:created_at)
make=->(actor,id,time,data) {record.new({'actor'=>actor,'data'=>data},actor,id,time)}
first=GameRoomTableVoice.transition(GameRoomTableVoice.empty,
  make.call('Alice','a',10,{'operation'=>'claim','previous'=>''}),owner:'Alice')
assert_equal(nil,GameRoomTableVoice.transition(first,
  make.call('Bob','too-early',39,{'operation'=>'claim','previous'=>'a'}),owner:'Alice'))
renewed=GameRoomTableVoice.transition(first,
  make.call('Bob','b',40,{'operation'=>'claim','previous'=>'a'}),owner:'Alice')
assert_equal('Bob',renewed['creator'])
assert_equal(nil,GameRoomTableVoice.transition(renewed,
  make.call('Alice','late-publish',41,payload.merge('previous'=>'a')),owner:'Alice'),
  'An expired creator published over the newer claim')
forged=make.call('Bob','forged',42,{'operation'=>'clear','previous'=>'b'})
forged.packet['actor']='Alice'
assert_equal(nil,GameRoomTableVoice.transition(renewed,forged,owner:'Alice'))
puts 'PASS native table Conference claims, expiry, authenticated sender, late arrival, single announcement, privacy, new-game checkpoint and new-owner reset'
