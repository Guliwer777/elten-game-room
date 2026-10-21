require_relative 'tournament_native'

# Native windows and button callbacks, with no injected key state or navigation
# checks. This also keeps focused integration tests usable while keyboard tests
# are intentionally excluded.
class TournamentControlCallbacks
  def initialize
    @steps = []
    @executing = {}.compare_by_identity
    SpeechOutput.reset
    NVDA.reset
    EltenAPI::KeyboardState.reset
    $native_tutorial_driver = self
  end

  def step(header, &action)
    @steps << [header, action]
  end

  def tick(form)
    # Keep the host's empty input snapshot current without synthesizing a
    # keypress or invoking its Windows keyboard backend.
    $input_frame_serial = $input_frame_serial.to_i + 1
    $keyboard_state_frame_serial = $input_frame_serial
    $keyboard_state_frame_thread = Thread.current
    return if @executing[form] || !form.is_a?(GameRoomUI::Form) || form.instance_variable_get(:@wait) != true
    header, action = @steps.shift || raise('Unexpected extra native form wait')
    raise "Expected #{header}, got #{form.fields.first.header}" unless header === form.fields.first.header
    @executing[form] = true
    action.call(form)
  ensure
    @executing.delete(form) if action
  end

  def finish
    raise 'Native window returned before all control callbacks' unless @steps.empty?
  end
end
