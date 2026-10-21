require_relative '../support/tournament_control_callbacks'
require_relative '../support/session_runner'
require_relative '../../lib/table_voice_screen'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

class LocalConferenceDevice
  attr_reader :created, :joined
  attr_accessor :channel, :join_success, :muted, :push_to_talk
  def initialize
    @created, @joined = [], []
    @join_success = true
    @muted, @push_to_talk = true, true
  end
  def opened?; !channel.nil?; end
  def create(*arguments); @created << arguments; 246; end
  def join(id, password)
    @joined << [id,password]
    @channel = Struct.new(:id).new(id) if join_success
    join_success
  end
end

def voice_program(notices, confirmations=[])
  Object.new.tap do |program|
    program.define_singleton_method(:run_network_task) { |*, **, &operation| operation.call }
    program.define_singleton_method(:alert) { |text| notices << text }
    program.define_singleton_method(:confirm) { |text| confirmations << text; true }
  end
end

def creation_step(driver, &before_create)
  driver.step('Channel name') do |form|
    form.fields[0].set_text('Table conference')
    form.fields[1].index=1
    form.fields[2].set_text('member-secret')
    before_create&.call
    form.fields.grep(Button).find { |button| button.label=='Create voice conversation' }.press
  end
end

h=NativeRoomHarness.new(users:%w[Alice Bob])
host, guest=h.transports.values_at('Alice','Bob')
notices, confirmations=[], []
program=voice_program(notices,confirmations)
conference=LocalConferenceDevice.new
conference.channel=Struct.new(:id).new(100)
driver=TournamentControlCallbacks.new
creation_step(driver)
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:conference).run }
driver.finish
assert_equal(1,conference.created.size)
assert_equal(['Table conference',false,64,60,1,0,false,false,'member-secret'],conference.created.first)
assert_equal([[246,'member-secret']],conference.joined)
assert_equal(1,confirmations.size,'Switching away from another Conference did not ask')
assert(conference.muted && conference.push_to_talk,'The table action changed microphone/PTT settings')
assert_equal([],notices)
assert_equal(1,h.as('Bob') { guest.activity_records(h.table).count { |row| row['kind']=='voice_started' } })

# An invited guest joins the existing Conference, never creates a new one.
other=LocalConferenceDevice.new
h.as('Bob') { GameRoomTableVoiceScreen.new(program:program,transport:guest,table:h.table,conference:other).run }
assert_equal([],other.created)
assert_equal([[246,'member-secret']],other.joined)
assert(other.muted && other.push_to_talk,'Joining changed the guest microphone/PTT settings')

# A stale channel leaves control with the user. A guest cannot remove another
# person's invitation; the creator may deliberately clear that exact head.
other.join_success=false
driver=TournamentControlCallbacks.new
driver.step('Voice conversation') do |form|
  assert_equal(['Back'],form.fields.grep(Button).map(&:label))
  form.fields.grep(Button).last.press
end
h.as('Bob') { GameRoomTableVoiceScreen.new(program:program,transport:guest,table:h.table,conference:other).run }
driver.finish
assert_equal('ready',h.as('Alice') { host.table_voice(h.table,force:true) }['status'])
conference.join_success=false
driver=TournamentControlCallbacks.new
driver.step('Voice conversation') do |form|
  form.fields.grep(Button).find { |button| button.label=='Remove this voice invitation' }.press
end
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:conference).run }
driver.finish
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])

# A concurrent creator claims the table while the original form is open.
race=LocalConferenceDevice.new
driver=TournamentControlCallbacks.new
creation_step(driver) do
  h.as('Bob') do
    current=guest.table_voice(h.table,force:true)
    accepted=guest.change_table_voice(h.table,{'operation'=>'claim','previous'=>current['head']},actor:'Bob')
    assert_equal(true,accepted[:accepted])
  end
end
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:race).run }
driver.finish
assert_equal([],race.created,'A lost claim still allocated a second Conference')
assert_equal([],race.joined)
assert_equal(['Someone is already preparing the voice conversation. Try again shortly.'],notices)
puts 'PASS native Conference controller callbacks: creation, guest join, explicit switch, mic/PTT preservation, failed join and concurrent claim; offline, no keyboard'

# A rejected creator join must not publish a ready invitation/announcement.
# Other table members should not receive a button targeting a dead channel.
rejected=LocalConferenceDevice.new
rejected.join_success=false
previous=h.as('Alice') { host.table_voice(h.table,force:true) }
h.as('Bob') { guest.change_table_voice(h.table,{'operation'=>'clear','previous'=>previous['head']},actor:'Bob') }
announcements=h.as('Bob') { guest.activity_records(h.table).count { |row| row['kind']=='voice_started' } }
driver=TournamentControlCallbacks.new
creation_step(driver)
driver.step('Voice conversation') do |form|
  assert_equal(['Back'],form.fields.grep(Button).map(&:label))
  form.fields.grep(Button).last.press
end
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:rejected).run }
driver.finish
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
assert_equal(announcements,h.as('Bob') { guest.activity_records(h.table).count { |row| row['kind']=='voice_started' } })
puts 'PASS rejected creator join clears its claim without publishing a ready invitation'
