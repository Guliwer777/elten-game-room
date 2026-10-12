require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckClientNativeControlsTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    cases = {
      'copy_number typing and refresh' => :typing_and_refresh,
      'copy_number countdown blocks early input and keeps chat available' => :countdown_input,
      'rhythm keys and covered deadlines' => :rhythm_keys_and_cover,
      'blackjack membership changes between frames' => :membership_change_between_frames,
      'sound_order previews without a list and ignores held repeats' => :sound_order_keys,
      'simon setup and close' => :setup_and_close
    }
    filter = Regexp.new(ENV.fetch('DUCK_NATIVE_CASE')) if ENV.key?('DUCK_NATIVE_CASE')
    selected = cases.select { |name, _method| !filter || filter.match?(name) }
    raise 'No native control scenarios matched DUCK_NATIVE_CASE' if selected.empty?
    selected.each_value { |method| send(method) }
    report('Duck client with native controls, shared progress, chat, help and covered deadlines')
  end

  def native_attach
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
  end

  def key_frame(events = [], held: [], characters: '', form: @form, milliseconds: 16)
    @program.now_ms += milliseconds
    @driver.frame(form, events, held: held, characters: characters)
    # GameScreen also calls tick from its ordinary presenter timer. Both
    # invocations share Progress's one monotonic gate, not two input loops.
    @client.tick
  end

  def typing_and_refresh
    setup_client('copy_number')
    native_attach
    field = @surface.fields.first
    400.times do
      key_frame
      break unless @client.local_view[:preparing]
    end
    assert(!@client.local_view[:preparing])
    answer = @client.instance_variable_get(:@trace).state[:model][:answer].to_s
    prefix = answer[0...-1]
    key_frame(@driver.tap(answer.getbyte(0)), characters: prefix)
    assert_equal(prefix, field.text)
    cursor = [field.index, field.check]
    trace = @client.instance_variable_get(:@trace)
    replace { |replay| replay.state[:round][:last_seen][1] += 10 }
    assert_equal(trace, @client.instance_variable_get(:@trace))
    assert_equal(field, @surface.fields.first)
    assert_equal(prefix, field.text)
    assert_equal(cursor, [field.index, field.check])
    key_frame(@driver.tap(0x09))
    chat = @form.fields.last
    assert_equal(chat, @form.fields[@form.index])
    key_frame(@driver.tap(0x0D))
    assert_equal(nil, request, 'Chat Enter became a quiz answer')
    draft = chat.text.dup
    key_frame(@driver.tap(0x09, modifiers: [0x10]))
    assert_equal(field, @form.fields[@form.index])
    key_frame(@driver.tap(answer.getbyte(-1)), characters: answer[-1])
    assert(request, 'Completing the answer after returning from chat did not submit automatically')
    assert_equal('submit_trace', request['action'])
    assert_equal(answer, request['trace']['actions'].last['input']['value'])
    assert_equal(false, @surface.presentation[:enabled])
    saved = Marshal.dump(request)
    key_frame(@driver.tap(0x0D))
    assert_equal(saved, Marshal.dump(request), 'Enter repeated the automatic answer')
    key_frame([[0x0D, :repeat]], held: [0x0D])
    assert_equal(saved, Marshal.dump(request))
    assert_equal(draft, chat.text)
    assert_equal(1, @game.loads)
  ensure
    close
  end

  def countdown_input
    setup_client('copy_number')
    native_attach
    field = @surface.fields.first
    answer = @client.instance_variable_get(:@trace).state[:model][:answer].to_s
    assert((field.flags & EditBox::Flags::ReadOnly) != 0)
    key_frame(@driver.tap(answer.getbyte(0)), characters: answer)
    assert_equal('', field.text, 'Early digits remained in the native answer field')
    assert_equal(nil, request)
    key_frame(@driver.tap(0x09))
    chat = @form.fields.last
    assert_equal(chat, @form.fields[@form.index])
    before = chat.text.dup
    key_frame(@driver.tap(0x58), characters: 'x')
    assert(chat.text != before, 'Countdown blocked unrelated chat typing')
    draft = chat.text.dup
    key_frame(@driver.tap(0x09, modifiers: [0x10]))
    400.times do
      key_frame(@driver.tap(answer.getbyte(0)), characters: answer)
      break unless @client.local_view[:preparing]
    end
    assert(!@client.local_view[:preparing])
    assert_equal(answer, field.text, 'A fresh digit batch on the completion frame was lost')
    key_frame if request.nil?
    assert_equal(0, field.flags & EditBox::Flags::ReadOnly)
    key_frame(@driver.tap(answer.getbyte(0)), characters: answer)
    assert_equal('submit_trace', request && request['action'])
    assert_equal(answer, request['trace']['actions'].last['input']['value'])
    assert_equal(draft, chat.text)
    assert_equal(1, @program.events.count { |event| event[:asset] == 'duck_countdown' })
  ensure
    close
  end

  def sound_order_keys
    setup_client('sound_order')
    native_attach
    finish_preparation(delay_ms: ENGINE::ORDER_PREPARATION_DELAY_MS)
    assert_equal(1, @program.events.count { |event| event[:asset] == 'duck_countdown' })
    @program.events.clear
    assert(@surface.fields.first.is_a?(Button))
    assert_equal([], @surface.presentation[:options])
    key_frame([[0x31, true]], held: [0x31])
    key_frame
    assert_equal(1, @program.events.length)
    20.times { key_frame([[0x31, :repeat]], held: [0x31]) }
    assert_equal(1, @program.events.length, 'Holding a digit repeatedly played its tone')
    key_frame([[0x31, false]])
    key_frame(@driver.tap(0x31))
    key_frame
    assert_equal(2, @program.events.length, 'A fresh press did not play the tone again')
    assert_equal(nil, request, 'Previewing tones wrote a game action')
    assert_equal(nil, @client.instance_variable_get(:@trace))
    assert_equal(0, @program.events.count { |event| event[:asset] == 'duck_countdown' })
  ensure
    close
  end

  def rhythm_keys_and_cover
    setup_client('rhythm')
    native_attach
    300.times do
      key_frame(milliseconds: 25)
      break if @client.local_view.dig(:own, :phase) == :ready
    end
    assert_equal(:ready, @client.local_view.dig(:own, :phase))
    key_frame(@driver.tap(0x0D))
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    key_frame(@driver.tap(0x46) + @driver.tap(0x4A) + @driver.tap(0x46))
    trace = @client.instance_variable_get(:@trace)
    actions = trace.instance_variable_get(:@actions)
    assert_equal(%w[f j f], actions.select { |entry| entry['input']['kind'] == 'tone' }.map { |entry| entry['input']['value'] })
    key_frame([[0x46, :repeat]], held: [0x46])
    assert_equal(3, actions.count { |entry| entry['input']['kind'] == 'tone' })
    key_frame([[0x46, false]])
    @form.show_game_room_help
    key_frame(@driver.tap(0x4A))
    assert_equal(3, actions.count { |entry| entry['input']['kind'] == 'tone' }, 'Help typed a beat')
    key_frame(@driver.tap(0x0D))
    assert_equal(false, @form.game_room_background_help?)
    key_frame(@driver.tap(0x4A))
    assert_equal(4, actions.count { |entry| entry['input']['kind'] == 'tone' })

    foreign = GameRoomUI::Form.new([ListBox.new(['Foreign window'], quiet: true)], quiet: true)
    $lastactivecontrols = [foreign]
    key_frame(@driver.tap(0x46), form: foreign, milliseconds: 100)
    assert_equal(4, actions.count { |entry| entry['input']['kind'] == 'tone' })
    @program.now_ms += 3_001
    @client.progress_frame(background: true)
    assert(trace.finished?, 'A covered native form stopped the deadline')
    assert_equal('submit_trace', request['action'])
    assert_equal(4, request['trace']['actions'].count { |entry| entry['input']['kind'] == 'tone' })
    assert_equal(1, @game.loads)
  ensure
    $lastactivecontrols = []
    close
  end

  def setup_and_close
    setup_client('simon')
    native_attach
    key_frame
    assert(@program.sounds.length.positive?)
    @client.detach_view
    assert_equal(nil, @progress.instance_variable_get(:@form))
    @program.now_ms += 250
    @client.progress_frame(background: true)
    assert_equal(false, @client.closed?)
    @client.attach_view(@form, @surface)
    @client.close
    assert(@progress.closed?)
    assert_equal([], @program.managed)
    assert(@program.sounds.all? { |sound| sound.closes == 1 })
    count = @program.events.length
    key_frame(@driver.tap(0x31))
    assert_equal(count, @program.events.length)
    assert_equal({}, @client.context_data)
  ensure
    close
  end

  def membership_change_between_frames
    setup_client('blackjack', players: %w[Alice Bob Charlie Dave], participants: [0, 1, 2, 3])
    native_attach
    key_frame
    old_replay = @replay
    changed_control = {'__players' => %w[Alice Bob Charlie Replacement], '__table_owner' => 'Alice'}
    # Membership may arrive repeatedly before the executor supplies the
    # cancellation replay. The real form timer still runs in between.
    3.times do
      @client.update_table_control(changed_control)
      key_frame
      @client.progress_frame(background: true)
      assert_equal(nil, @client.instance_variable_get(:@trace))
      assert_equal(nil, request)
      assert_equal(false, @client.context_data['duck_ready'])
    end
    @replay = Marshal.load(Marshal.dump(old_replay))
    @replay.players[3] = 'Replacement'
    @replay.state[:revision] += 1
    @replay.state[:last_resolution] = {id: 1, kind: 'blackjack', cancelled: :participant_changed}
    @replay.state[:round] = @replay.state[:race][:challenge] = nil
    @client.before_wait(@replay, @viewer)
    # The old bug left @challenge behind after clearing @identity. With no
    # round in the new replay, frame -> queue_pulse raised NoMethodError.
    3.times do
      key_frame
      @client.update_table_control(changed_control)
      @client.progress_frame(background: true)
      assert_equal(nil, request)
      assert_equal(nil, @client.local_view)
      assert_equal(false, @client.context_data['duck_ready'])
      assert_equal(false, @progress.closed?)
    end
    assert_equal(false, @client.before_wait(old_replay, @viewer))
    assert_equal(nil, @client.instance_variable_get(:@trace))
    close

    setup_client('blackjack', players: %w[Alice Bob Charlie Dave], participants: [0, 1, 2, 3])
    native_attach
    original = @replay
    @client.update_table_control(changed_control)
    # A foreground refresh with the pre-membership state must not restart
    # a public turn while waiting for the authoritative result.
    3.times do
      @client.before_wait(original, @viewer)
      key_frame
      assert_equal(nil, @client.instance_variable_get(:@trace))
      assert_equal(nil, request)
      assert_equal(false, @client.context_data['duck_ready'])
    end
    # Starting seats are shuffled. This scenario needs Alice's next legal
    # turn, not an assumption that the first listed participant always starts.
    seed = (0...100).find do |candidate|
      replay = make_replay('blackjack', seed: candidate,
        players: %w[Alice Bob Charlie Replacement], participants: [0, 1, 2, 3])
      ENGINE.current_turn(replay.state[:round][:engine]) == 0
    end
    assert(seed, 'No fixture with Alice starting after replacement')
    next_replay = make_replay('blackjack', id: 2, seed: seed,
      players: %w[Alice Bob Charlie Replacement], participants: [0, 1, 2, 3])
    next_replay.state[:revision] = original.state[:revision] + 2
    @replay = next_replay
    @client.before_wait(@replay, @viewer)
    native_attach
    key_frame
    assert_equal(nil, @client.instance_variable_get(:@trace), 'Public blackjack unexpectedly created a private attempt')
    assert_equal('blackjack', @client.local_view&.fetch(:type), 'The next legitimate challenge remained blocked')
    assert_equal(0, @client.local_view[:turn_seat])
    key_frame(@driver.tap(0x0D))
    assert_equal('input', request['action'])
    assert_equal('stand', request.dig('input', 'kind'))
    assert_equal(2, request['challenge'])
  ensure
    close
  end
end

DuckClientNativeControlsTest.new.run
