require_relative 'client_helpers'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_event_presenter'

# Exercise both presentation paths together, not just the client's sound queue.
class DuckMemoryOrderingTest
  include DuckClientTest

  def run
    %w[Alice Bob Observer].each do |viewer|
      [false, true].each { |covered| ordered_match(viewer, covered) }
    end
    missed_pair
    timeout_turns
    close_during_feedback
    report('Duck memory: feedback before turns/results through the shared presenter')
  end

  def setup_memory(viewer, covered = false)
    @h = DuckGameAdapterTest::Harness.new(kind: 'sound_memory')
    @id = @h.open_round(group: false)[:id]
    @h.begin_round
    @replay, @viewer, @game = @h.replay, viewer, @h.game
    @program = DuckChallengeAudioTest::Program.new
    @client = CLIENT.new(@program, @game, clock: -> { @program.now_ms / 1000.0 },
      session_time: ->(_state) { @h.now_ms },
      presentation_busy: -> { @presenter&.event_presentation_busy? },
      realtime_factory: -> { Realtime.new(@program) },
      progress_factory: ->(**_options, &block) { @progress = Progress.new(&block) })
    @client.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: viewer, members: -> { @h.players })
    @client.start
    @progress.covered = covered
    @client.update_table_control(@h.session)
    @presenter = GameRoomEventPresenter.new(game: -> { @game }, repository: -> { @h.repository },
      program: -> { @program }, viewer: -> { viewer }, client: -> { @client }, surface_state: -> { {} },
      clock: -> { @program.now_ms / 1000.0 }, covered: -> { covered },
      speech: ->(text) { $spoken_messages << text }, trace: ->(*_args, **_options) {},
      history_changed: ->(*_args) {}, session_changed: -> {})
    @presenter.process_new_events(@replay, session: @h.session)
    @client.before_wait(@replay, viewer)
    $spoken_messages.clear
  end

  def model; @replay.state[:round][:engine][:model]; end
  def digit(index); index == 9 ? 0 : index + 1; end

  def choose(index)
    @press = @press.to_i + 1
    @h.accept({'action' => 'input', 'challenge' => @id,
      'input' => {'kind' => 'reveal', 'value' => digit(index), 'press_id' => @press}},
      actor: @replay.players.fetch(model[:public][:turn]))
    @replay = @h.replay
  end

  def deliver
    @presenter.process_new_events(@replay, session: @h.session)
    @client.before_wait(@replay, @viewer)
  end

  def drain
    600.times do
      @program.now_ms += 25
      @presenter.event_presentation&.advance
      @client.progress_frame(background: @progress.covered?)
      return unless @presenter.event_presentation_busy? || @client.instance_variable_get(:@memory_presenters).any?
    end
    raise 'Memory presentation did not finish'
  end

  def ordered_match(viewer, covered)
    setup_memory(viewer, covered)
    pairs = model[:private][:pairs].each_index.group_by { |index| model[:private][:pairs][index] }.values
    pairs.each_with_index do |pair, index|
      actor = @replay.players.fetch(model[:public][:turn])
      pair.each { |position| choose(position) } # two choices in one refresh
      deliver
      drain
      expected = pair.map { |position| "#{actor}: #{digit(position)}." } + ['Correct!']
      assert_equal(expected, $spoken_messages.take(3), 'Turn or pair totals overtook feedback')
      if index < pairs.length - 1
        player = @replay.players.fetch(model[:public][:turn])
        assert_equal(["#{player}'s turn."], $spoken_messages.drop(3), 'Next player missing or announced twice')
      else
        assert($spoken_messages.drop(3).any? { |text| text.include?('pair') }, 'Final pair totals missing')
      end
      assert(@replay.history.none? { |entry| expected.include?(entry.text) }, 'Memory hint was saved in history')
      spoken = $spoken_messages.dup
      2.times { deliver; drain }
      assert_equal(spoken, $spoken_messages, 'Repeated snapshot repeated feedback')
      $spoken_messages.clear
    end
    assert_equal(nil, @replay.state[:round])
  ensure
    @presenter&.event_presentation&.close
    close
  end

  def missed_pair
    setup_memory('Alice')
    other = model[:private][:pairs].each_index.find { |i| model[:private][:pairs][i] != model[:private][:pairs][0] }
    actor = @replay.players.fetch(model[:public][:turn])
    choose(0)
    deliver
    drain
    assert_equal(["#{actor}: 1."], $spoken_messages)
    choose(other)
    deliver
    drain
    player = @replay.players.fetch(model[:public][:turn])
    assert_equal(["#{actor}: 1.", "#{actor}: #{digit(other)}.", 'Wrong!', "#{player}'s turn."], $spoken_messages)
  ensure
    @presenter&.event_presentation&.close
    close
  end

  def timeout_turns
    setup_memory('Alice')
    start = @replay.state[:round][:started_at]
    [30_000, 45_000].each do |elapsed|
      @h.accept({'action' => 'advance', 'challenge' => @id}, at: start + elapsed)
      @replay = @h.replay
      deliver
      drain
      player = @replay.players.fetch(model[:public][:turn])
      assert_equal(["#{player}'s turn."], $spoken_messages, 'Expired turns lost the next-player announcement')
      assert_equal([], @program.events, 'A timeout replayed a previous choice')
      $spoken_messages.clear
    end
  ensure
    @presenter&.event_presentation&.close
    close
  end

  def close_during_feedback
    setup_memory('Alice')
    choose(0)
    deliver
    @client.progress_frame
    assert(@presenter.event_presentation_busy?)
    assert(!@program.managed.empty?)
    @presenter.event_presentation.close
    close
    assert_equal([], @program.managed, 'Closing the shared queue retained client playback')
    spoken = $spoken_messages.dup
    drain
    assert_equal(spoken, $spoken_messages, 'Closing played pending feedback')
  ensure
    @presenter&.event_presentation&.close
    close
  end
end

DuckMemoryOrderingTest.new.run
