require 'json'
require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'
require_relative '../../../lib/game_room_pending_operation'

class DuckNativeNumericRefreshContractTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    cases = %w[copy_number arithmetic race_question guess_number count_ducks].map do |kind|
      ["return and refresh: #{kind}", -> { return_and_refresh(kind) }]
    end
    cases += [
      ['unrelated native edit preserves a partial number', -> { partial_number }],
      ['blur still discards unconsumed commands', -> { discarded_after(:blur) }],
      ['covered fields still discard unconsumed commands', -> { discarded_after(:covered) }],
      ['new challenge rejects the previous field', -> { discarded_after(:challenge) }],
      ['changed membership rejects the previous attempt', -> { discarded_after(:roster) }],
      ['phase and native-control boundaries', -> { surface_boundaries }]
    ]
    results = cases.map do |name, action|
      begin
        action.call
        {case: name, status: 'PASS'}
      rescue StandardError => error
        {case: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
      ensure
        @operation&.close
        @operation = nil
        close
        $lastactivecontrols = $activecontrols = []
      end
    end
    puts JSON.pretty_generate(results: results, checks: @checks)
    assert(results.all? { |row| row[:status] == 'PASS' }, 'Native numeric refresh contract failed')
  end

  def setup_ready(kind = 'copy_number')
    setup_client(kind)
    @layout = GameRoomLayout::Screen.new(view_spec: view, user_items: @replay.players,
      users_header: 'Players', own_table: true)
    @layout.session_id = 91
    @form, @surface = @layout.form, @layout.surface
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    @form.focus
    3_000.times do
      frame
      break if @surface.presentation[:enabled] &&
        (kind != 'count_ducks' || @surface.presentation[:phase] == :responding)
    end
    assert(@surface.presentation[:enabled], "The #{kind} input never opened")
    assert_equal(:responding, @surface.presentation[:phase]) if kind == 'count_ducks'
    @trace = @client.instance_variable_get(:@trace)
    @answer = ENGINE.solution(@replay.state[:round][:challenge], resources: resources).to_s
    assert_equal(@answer.length, @surface.presentation[:auto_submit_length])
    assert_equal(nil, request)
  end

  def view(spec = @client.surface_spec(@replay, @viewer))
    GameRoomLayout::ViewSpec.new(surface: spec)
  end

  def frame(characters = '')
    @program.now_ms += 10
    @driver.frame(@form, characters.chars.flat_map { |char| @driver.tap(char.ord) }, characters: characters)
  end

  def refresh(spec: @client.surface_spec(@replay, @viewer), **options)
    @layout.update(view_spec: view(spec), history_items: [], user_items: @replay.players,
      users_header: 'Players', own_table: true, **options)
    @surface = @layout.surface
    @client.attach_view(@form, @surface)
  end

  def unrelated_commit
    @replay = Marshal.load(Marshal.dump(@replay))
    @replay.state[:revision] += 1
    @replay.state[:round][:last_seen][1] += 1
    control
    @client.before_wait(@replay, @viewer)
  end

  def complete_on_return
    frame(@answer[0...-1]) unless @answer.length == 1
    frame
    # All outer frames are 10 ms apart. The registered background presenter
    # can run before the returning Form in the SAME frame, while the native
    # host still records Messages as the previous active control.
    $lastactivecontrols = [EditBox.new('Messages', text: '', quiet: true)]
    @program.now_ms += 10
    presentation = @progress.instance_variable_get(:@presentation)
    assert(presentation.covered?)
    presentation.tick
    @program.now_ms += 1
    @driver.frame(@form, @driver.tap(@answer[-1].ord), characters: @answer[-1])
    @field = @surface.fields.first
    assert_equal(@answer, @field.text, 'The native edit did not receive the final digit')
    assert($activecontrols.include?(@field), 'The native control never became active')
    assert_equal(1, @surface.instance_variable_get(:@pending).length)
    assert_equal(nil, request, 'This fixture must defer consumption until the next Progress slot')
  end

  def return_and_refresh(kind)
    setup_ready(kind)
    @operation = GameRoomUI::PendingOperation.new(layout: @layout, table_id: 18, session_id: 91,
      token: EltenAPI::Tasks::CancellationToken.new, title: 'Refreshing another player',
      local_input: @client.method(:local_input_during_operation?))
    complete_on_return
    selection = [@field.index, @field.check]
    unrelated_commit
    refresh
    assert(@field.equal?(@surface.fields.first), 'An unrelated commit replaced the native answer control')
    assert_equal(selection, [@field.index, @field.check])
    assert_equal(1, @surface.instance_variable_get(:@pending).length)
    assert_equal(@trace, @client.instance_variable_get(:@trace), 'Refresh restarted the private attempt')
    @operation.close
    $lastactivecontrols = [@form]
    4.times { frame }
    assert(@trace.finished?, 'A complete native answer needed another key after refresh')
    actions = @trace.instance_variable_get(:@actions)
    assert_equal(1, actions.count { |entry| entry['input']['kind'] == 'answer' })
    assert_equal(@answer, actions.last['input']['value'].to_s)
    assert(request, 'The finished attempt was not offered to the ordinary runner')
    original = Marshal.dump(request)
    3.times { unrelated_commit; refresh; frame }
    assert_equal(original, Marshal.dump(request), 'A refresh duplicated or replaced the accepted attempt')
    assert_equal(1, actions.count { |entry| entry['input']['kind'] == 'answer' })
  end

  def partial_number
    setup_ready
    frame(@answer[0])
    field = @surface.fields.first
    selection = [field.index, field.check]
    unrelated_commit
    refresh
    assert(field.equal?(@surface.fields.first))
    assert_equal(@answer[0], field.text)
    assert_equal(selection, [field.index, field.check])
    assert_equal(nil, request)
    frame(@answer[1..])
    2.times { frame }
    assert_equal(@answer, request.dig('trace', 'actions').last.dig('input', 'value'))
  end

  def discarded_after(boundary)
    setup_ready
    complete_on_return
    case boundary
    when :blur
      @form.index = @form.fields.index(@layout.chat)
      @program.now_ms += 10
      @client.tick
      refresh
    when :covered
      $lastactivecontrols = [EditBox.new('Messages', text: '', quiet: true)]
      @program.now_ms += 10
      @progress.instance_variable_get(:@presentation).tick
      unrelated_commit
      refresh
    when :challenge
      @replay = make_replay('copy_number', id: 2)
      control
      @client.before_wait(@replay, @viewer)
      refresh
      assert(!@field.equal?(@surface.fields.first))
      assert_equal('', @surface.fields.first.text)
      assert_equal(nil, @field.duck_surface.before_input)
    when :roster
      @client.update_table_control({'__players' => %w[Alice Diana Charlie], '__table_owner' => 'Alice', '__control_epoch' => 'changed'})
      @client.before_wait(@replay, @viewer)
      assert(!@client.local_input_during_operation?(@surface))
    end
    assert_equal([], @field.duck_surface.instance_variable_get(:@pending))
    $lastactivecontrols = [@form]
    @layout.focus_game
    3.times { frame }
    assert_equal(nil, request, "A #{boundary} field submitted the old pending answer")
    assert_equal([], @trace.instance_variable_get(:@actions))
  end

  def surface_boundaries
    setup_ready
    complete_on_return
    original = @surface.spec
    # A phase change can reuse the field, but must clear its old commands.
    changed = original.dup
    changed.view = Marshal.load(Marshal.dump(original.view)).merge(finished: true)
    @layout.update(view_spec: view(changed), history_items: [], user_items: @replay.players,
      users_header: 'Players', own_table: true)
    assert(@field.equal?(@layout.surface.fields.first))
    assert_equal([], @layout.surface.instance_variable_get(:@pending))
    assert_equal([], @layout.surface.take_input(@form))

    # Neither a new viewer nor an observer/participant native-control change
    # may reuse the original field, even with the same challenge identifier.
    changed = original.dup
    changed.viewer = 1
    assert(!@surface.reusable_for?(changed))
    changed = original.dup
    changed.kind = 'guess_number'
    assert(!@surface.reusable_for?(changed))
    changed = original.dup
    changed.view = Marshal.load(Marshal.dump(original.view)).merge(participants: [1], seats: [1])
    assert(!@surface.reusable_for?(changed))
    @layout.update(view_spec: view(changed), history_items: [], user_items: @replay.players,
      users_header: 'Players', own_table: true)
    assert(@layout.surface.fields.first.is_a?(Button))
    assert_equal([], @layout.surface.take_input(@form))

    @layout.update(view_spec: view(original), history_items: [], user_items: @replay.players,
      users_header: 'Players', own_table: true, reset_surface: true)
    assert(@layout.surface.fields.first.is_a?(EditBox))
    assert(!@field.equal?(@layout.surface.fields.first))
    assert_equal([], @layout.surface.take_input(@form))
  end
end

DuckNativeNumericRefreshContractTest.new.run
