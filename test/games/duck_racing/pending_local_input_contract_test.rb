require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'
require_relative '../../../lib/game_room_pending_operation'

class DuckPendingLocalInputContractTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    final_digit_during_request
    changed_challenge
    changed_roster
    nonparticipant
    report('Duck pending local input with native controls: complete edit once, identity/roster boundaries and observer restriction')
  end

  def setup_ready(viewer: 'Alice')
    setup_client('copy_number', viewer: viewer)
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    @field = @surface.fields.first
    @notices = []
    @form.define_singleton_method(:speak) { |message, *| @pending_contract_notices << message }
    @form.instance_variable_set(:@pending_contract_notices, @notices)
    return unless viewer == 'Alice'
    (ENGINE::PREPARATION_MS.div(16) + 5).times do
      frame
      break unless @client.local_view[:preparing]
    end
    assert(!@client.local_view[:preparing], 'The fixture did not finish ordinary challenge preparation')
  end

  def frame(characters = '')
    @program.now_ms += 16
    keys = characters.empty? ? [] : @driver.tap(characters.getbyte(0))
    @driver.frame(@form, keys, characters: characters)
    @client.tick
  end

  def gate
    layout = Struct.new(:form, :surface, :binding_generation, :session_id).new(@form, @surface, 1, 91)
    GameRoomUI::PendingOperation.new(layout: layout, table_id: 18, session_id: 91,
      token: EltenAPI::Tasks::CancellationToken.new, title: 'Refreshing another player',
      local_input: @client.method(:local_input_during_operation?))
  end

  def final_digit_during_request
    setup_ready
    trace = @client.instance_variable_get(:@trace)
    answer = trace.state[:model][:answer].to_s
    frame(answer[0...-1]) unless answer.length == 1
    pending = gate
    assert(@client.local_input_during_operation?(@surface), 'The current participant attempt was not locally admissible')
    frame(answer[-1])
    assert_equal(answer, @field.text, 'A pending read lost the final native digit')
    assert_equal('submit_trace', request && request['action'], 'The completed native edit still needs another Enter after refresh')
    assert_equal(answer, request['trace']['actions'].last['input']['value'])
    assert_equal([], @notices, 'A valid local answer announced Please wait')
    saved = Marshal.dump(request)
    pending.close
    5.times { frame }
    assert_equal(saved, Marshal.dump(request), 'Finishing the request duplicated or replaced the accepted local trace')
    assert_equal(trace, @client.instance_variable_get(:@trace), 'Refresh restarted the private attempt')
  ensure
    pending&.close
    close
  end

  def changed_challenge
    setup_ready
    answer = @client.instance_variable_get(:@trace).state[:model][:answer].to_s
    frame(answer[0...-1]) unless answer.length == 1
    pending = gate
    @replay = make_replay('copy_number', id: 2)
    control
    @client.before_wait(@replay, @viewer)
    assert(!@client.local_input_during_operation?(@surface), 'Old controls retained permission for a new challenge identity')
    frame(answer[-1])
    assert_equal(nil, request, 'A final digit from the previous challenge was queued in the new challenge')
  ensure
    pending&.close
    close
  end

  def changed_roster
    setup_ready
    pending = gate
    @client.update_table_control({'__players' => %w[Alice Diana Charlie], '__table_owner' => 'Alice', '__control_epoch' => 'changed'})
    assert(!@client.local_input_during_operation?(@surface), 'An old attempt remained admissible after participant replacement')
    frame('9')
    assert_equal(nil, request, 'A stale-roster input escaped the pending operation')
  ensure
    pending&.close
    close
  end

  def nonparticipant
    setup_ready(viewer: 'Charlie')
    assert(!@client.local_input_during_operation?(@surface), 'An observer received participant input permission')
    @client.close
    assert(!@client.local_input_during_operation?(@surface), 'A closed client retained local-input permission')
  ensure
    close
    $lastactivecontrols = []
    $activecontrols = []
  end
end

DuckPendingLocalInputContractTest.new.run
