require_relative 'client_helpers'
require_relative '../../support/duck_game_adapter'

class DuckMemoryFeedbackTest
  include DuckClientTest

  def run
    %w[Alice Bob Observer].each { |viewer| match_feedback(viewer) }
    missed_pair
    cold_entry_and_cancel
    muted_feedback
    report('Duck memory: every accepted digit, transient feedback, audio ordering and no history hints')
  end

  def setup_memory(viewer = 'Alice')
    @harness = DuckGameAdapterTest::Harness.new(kind: 'sound_memory')
    @harness.open_round(group: false)
    @challenge_id = @harness.begin_round
    @replay, @viewer = @harness.replay, viewer
    @program = DuckChallengeAudioTest::Program.new
    @game = @harness.game
    @client = CLIENT.new(@program, @game, clock: -> { @program.now_ms / 1000.0 },
      session_time: ->(_state) { @harness.now_ms },
      realtime_factory: -> { Realtime.new(@program) },
      progress_factory: ->(**_options, &block) { @progress = Progress.new(&block) })
    @client.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: viewer, members: -> { @harness.players })
    @client.start
    @client.update_table_control(@harness.session)
    @client.before_wait(@replay, viewer)
    $spoken_messages.clear
  end

  def model; @replay.state[:round][:engine][:model]; end
  def digit(index); index == 9 ? 0 : index + 1; end
  def feedback; $spoken_messages.reject { |message| message == 'Your turn.' }; end

  def choose(position, deliver: true)
    before = @replay
    actor = before.players.fetch(model[:public][:turn])
    @press = @press.to_i + 1
    @harness.accept({'action' => 'input', 'challenge' => @challenge_id,
      'input' => {'kind' => 'reveal', 'value' => position, 'press_id' => @press}}, actor: actor)
    @replay = @harness.replay
    transition = [@replay.accepted_events.last, before, @replay, @viewer, @harness.repository]
    @client.event(*transition) if deliver
    @client.before_wait(@replay, @viewer)
    transition
  end

  def finish_audio
    200.times do
      advance(@program.now_ms + 25)
      return if @client.instance_variable_get(:@memory_presenters).empty?
    end
    raise 'Memory feedback did not finish'
  end

  def match_feedback(viewer)
    setup_memory(viewer)
    pairs = model[:private][:pairs].each_index.group_by { |index| model[:private][:pairs][index] }.values
    expected_messages, expected_assets = [], []
    pairs.each do |pair|
      actor = @replay.players.fetch(model[:public][:turn])
      tone = model[:private][:pairs][pair.first]
      transitions = pair.map { |index| choose(digit(index), deliver: false) }
      # Multiple accepted choices delivered by one refresh must stay ordered.
      transitions.each { |transition| @client.event(*transition) }
      transitions.each { |transition| @client.event(*transition) }
      expected_messages.concat(pair.map { |index| "#{actor}: #{digit(index)}." } + ['Correct!'])
      expected_assets.concat([GameRoomDuckRacing::ChallengeAudio::MEMORY_ASSETS[tone - 1]] * 2 + ['replay'])
      finish_audio
      assert_equal(expected_messages, feedback, "#{viewer}: missing or repeated transient feedback")
      assert_equal(expected_assets, @program.events.map { |event| event[:asset] })
      assert(@replay.history.none? { |entry| expected_messages.include?(entry.text) }, 'A memory hint entered game history')
      snapshot = [$spoken_messages.dup, @program.events.dup]
      3.times { @client.before_wait(@replay, viewer); advance(@program.now_ms + 25) }
      assert_equal(snapshot, [$spoken_messages, @program.events], 'Refresh repeated an old hint')
    end
    assert_equal(nil, @replay.state[:round], 'The final pair did not settle the challenge')
    @program.events.each_cons(2) do |previous, following|
      assert(following[:at] >= previous[:at] + previous[:sound].length * 1000, 'Feedback cut off an uncovered sound')
    end
    close
    assert_equal([], @program.managed, 'Closing left feedback sound handles alive')
  ensure
    close
  end

  def missed_pair
    setup_memory
    actor = @replay.players.fetch(model[:public][:turn])
    other = (0...9).find { |index| model[:private][:pairs][index] != model[:private][:pairs][9] }
    history = @replay.history.map(&:text)
    choose(0)
    advance(1)
    assert_equal(["#{actor}: 0."], feedback, 'The first digit was not announced immediately')
    choose(digit(other))
    finish_audio
    assert_equal(["#{actor}: 0.", "#{actor}: #{digit(other)}.", 'Wrong!'], feedback)
    assert_equal('buzzer', @program.events.last[:asset], 'Mismatch used the UNO call rather than its buzzer')
    assert_equal(history, @replay.history.map(&:text), 'A failed attempt left a searchable hint')
    assert_equal([], model[:public][:removed])
  ensure
    close
  end

  def cold_entry_and_cancel
    setup_memory
    choose(1, deliver: false)
    finish_audio
    assert_equal([], feedback, 'A snapshot replayed an already uncovered sound')
    before = @replay
    @harness.accept({'action' => 'alive', 'challenge' => @challenge_id}, actor: 'Alice',
      at: @replay.state[:round][:last_seen].fetch(0) + GameRoomDuckRacing::Session::PULSE_MS)
    @replay = @harness.replay
    @client.event(@replay.accepted_events.last, before, @replay, @viewer, @harness.repository)
    @client.before_wait(@replay, @viewer)
    finish_audio
    assert_equal([], feedback, 'An unrelated event replayed a hint from before joining')
    close
    setup_memory
    choose(1)
    choose(2)
    @harness.accept({'action' => 'cancel', 'challenge' => @challenge_id, 'reason' => 'technical'})
    @client.before_wait(@harness.replay, @viewer)
    finish_audio
    assert_equal([], feedback, 'Cancelled challenge kept announcing pending hints')
    assert_equal([], @program.managed)
  ensure
    close
  end

  def muted_feedback
    setup_memory
    DuckChallengeAudioTest::Program.settings = {'background_table_speech' => false}
    @progress.covered = true
    @program.enabled = false
    pair = model[:private][:pairs].each_index.group_by { |index| model[:private][:pairs][index] }.values.first
    pair.each { |index| choose(digit(index)) }
    finish_audio
    assert_equal([], feedback, 'Covered muted game spoke a hint')
    assert_equal(3, @program.events.length)
    assert(@program.events.all? { |event| event[:volume].zero? }, 'Muted feedback was audible')
  ensure
    DuckChallengeAudioTest::Program.settings = nil
    close
  end
end

DuckMemoryFeedbackTest.new.run
