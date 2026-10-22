require_relative '../support/tournament_control_callbacks'
require_relative '../support/session_runner'
require_relative '../../lib/table_voice_screen'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

class LocalConferenceDevice
  attr_reader :created, :joined, :leaves, :hooks
  attr_accessor :channel, :join_success, :muted, :push_to_talk, :auto_connect, :leave_success
  def initialize
    @created, @joined = [], []
    @hooks, @leaves = [], 0
    @auto_connect, @leave_success = true, true
    @join_success = true
    @muted, @push_to_talk = true, true
  end
  def opened?; !channel.nil?; end
  def on(event,&block); @hooks << [event,block]; @hooks.last; end
  def remove_hook(hook); @hooks.delete(hook); end
  def leave
    @leaves += 1
    @channel = Struct.new(:id).new(0) if leave_success
    leave_success
  end
  def create(*arguments)
    @created << arguments
    complete_creation if auto_connect
    246
  end
  def complete_creation
    person=Struct.new(:name).new(Session.name)
    @channel=Struct.new(:id,:name,:users).new(246,@created.last.first,[person])
    @hooks.each { |event,callback| callback.call if event==:update }
  end
  def join(id, password)
    @joined << [id,password]
    @channel = Struct.new(:id,:name).new(id,'Table conference') if join_success
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
assert_equal([],conference.joined,'Native create already joins its creator; a second join can destroy a temporary channel')
assert_equal(1,conference.leaves,'Previous native membership was not released before creation')
assert_equal([],conference.hooks,'The creation observer survived the operation')
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

# A connected guest leaves locally without clearing the shared invitation or
# emitting a new creation event. Returning to the conversation remains possible.
published=h.as('Alice') { host.table_voice(h.table,force:true) }
h.as('Bob') { GameRoomTableVoiceScreen.new(program:program,transport:guest,table:h.table,conference:other).run }
assert_equal(1,other.leaves,'A joined guest could not leave the native conversation')
assert_equal(published,h.as('Alice') { host.table_voice(h.table,force:true) },'Guest disconnect changed the shared invitation')
assert_equal(1,other.joined.size,'Guest disconnect issued another join')
assert_equal(1,h.as('Alice') { host.activity_records(h.table).count { |row| row['kind']=='voice_started' } })
assert(other.muted && other.push_to_talk,'Guest disconnect changed microphone/PTT settings')

# A guest cannot remove another person's invitation after a failed join.
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
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:conference).run }
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
assert_equal(2,conference.leaves,'The creator did not disconnect')

# Clearing the invitation does not eject an already joined guest. Its retained
# local target still permits leaving, without recreating/clearing anything.
orphan=LocalConferenceDevice.new
orphan.channel=Struct.new(:id,:name).new(246,'Table conference')
cleared=h.as('Bob') { guest.table_voice(h.table,force:true) }
h.as('Bob') { GameRoomTableVoiceScreen.new(program:program,transport:guest,table:h.table.merge('voice'=>published),conference:orphan).run }
assert_equal(1,orphan.leaves,'A remaining guest could not leave after the creator cleared the invitation')
assert_equal(cleared,h.as('Bob') { guest.table_voice(h.table,force:true) })

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

# An unconfirmed native creation must not publish a ready invitation.
rejected=LocalConferenceDevice.new
rejected.auto_connect=false
previous=h.as('Alice') { host.table_voice(h.table,force:true) }
h.as('Bob') { guest.change_table_voice(h.table,{'operation'=>'clear','previous'=>previous['head']},actor:'Bob') }
announcements=h.as('Bob') { guest.activity_records(h.table).count { |row| row['kind']=='voice_started' } }
driver=TournamentControlCallbacks.new
creation_step(driver)
driver.step('Voice conversation') do |form|
  assert_equal('Connecting to the voice conversation...',form.fields.first.text)
  form.fields.grep(Button).last.press
end
driver.step('Voice conversation') do |form|
  assert_equal(['Back'],form.fields.grep(Button).map(&:label))
  form.fields.grep(Button).last.press
end
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:rejected).run }
driver.finish
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
assert_equal(announcements,h.as('Bob') { guest.activity_records(h.table).count { |row| row['kind']=='voice_started' } })
assert_equal([],rejected.joined)
assert_equal([],rejected.hooks)
puts 'PASS unconfirmed native creation clears its claim without publishing an invitation or retrying join'

# The asynchronous native update completes on the ordinary form update path.
delayed=LocalConferenceDevice.new
delayed.auto_connect=false
driver=TournamentControlCallbacks.new
creation_step(driver)
driver.step('Voice conversation') do |form|
  delayed.complete_creation
  form.update
end
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:delayed).run }
driver.finish
assert_equal('ready',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
assert_equal([],delayed.joined)
assert_equal([],delayed.hooks)

# Clearing our invitation must never leave an unrelated conference.
delayed.channel=Struct.new(:id,:name).new(246,'Unrelated channel using a recycled native ID')
leaves=delayed.leaves
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:delayed).run }
assert_equal(leaves,delayed.leaves)
assert_equal('Unrelated channel using a recycled native ID',delayed.channel.name)
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
puts 'PASS native update confirmation and creator disconnect preserve unrelated conferences and remove hooks'

blocked=LocalConferenceDevice.new
blocked.channel=Struct.new(:id).new(100)
blocked.leave_success=false
driver=TournamentControlCallbacks.new
creation_step(driver)
h.as('Alice') { GameRoomTableVoiceScreen.new(program:program,transport:host,table:h.table,conference:blocked).run }
driver.finish
assert_equal([],blocked.created,'Creation continued after the previous native membership could not be released')
assert_equal([],blocked.hooks)
assert_equal('none',h.as('Bob') { guest.table_voice(h.table,force:true) }['status'])
assert_equal('The voice channel could not be created.',notices.last)
puts 'PASS failed native leave clears only its creation claim and does not allocate a channel'
