require_relative 'client_helpers'

class DuckSpeedPreparationTest
  include DuckClientTest

  def run
    (ENGINE::SPEED_TYPES - ['count_ducks']).each { |kind| preparation(kind) }
    numeric_answer
    delayed_frame
    playback_device_boundaries
    count_playback_and_replay
    covered_and_cancelled
    observer
    report('Duck speed preparation, cue, input boundary, response clock and playback replay')
  end

  def cues
    @program.events.select { |event| event[:asset] == GameRoomDuckRacing::ChallengeAudio::COUNTDOWN_ASSET }
  end

  def trace
    @client.instance_variable_get(:@trace)
  end

  def preparation(kind)
    setup_client(kind)
    original = trace
    assert_equal(true, @client.local_view[:preparing])
    assert_equal(false, @surface.presentation[:enabled])
    advance(0)
    advance(4_999)
    assert_equal([], cues)
    advance(5_000)
    @surface.push(:answer, value: 999)
    advance(ENGINE::PREPARATION_MS - 1)
    assert_equal([ENGINE::PREPARATION_DELAY_MS], cues.map { |event| event[:at] })
    assert(@client.local_view[:preparing])
    assert_equal(false, trace.finished?)
    replace { |replay| replay.state[:round][:last_seen][1] += 1 }
    assert_equal(original, trace)
    @surface.push(:answer, value: 999)
    advance(ENGINE::PREPARATION_MS)
    assert_equal([ENGINE::PREPARATION_DELAY_MS], cues.map { |event| event[:at] })
    assert(!@client.local_view[:preparing])
    assert_equal(true, @surface.presentation[:enabled])
    advance(ENGINE::PREPARATION_MS + 1)
    assert_equal(false, trace.finished?, 'A pre-cue input survived into the timed attempt')
    assert_equal([], trace.instance_variable_get(:@actions))
    3.times { replace; @client.tick }
    assert_equal(1, cues.length, 'A refresh repeated the starting cue')
    deadline = trace.state[:model][:deadline_ms] || trace.state[:model].dig(:private, :players, 0, :deadline_ms)
    assert(deadline, "No actual response deadline for #{kind}")
    advance(ENGINE::PREPARATION_MS + deadline - 1)
    assert_equal(false, trace.finished?)
    advance(ENGINE::PREPARATION_MS + deadline)
    assert(trace.finished?)
    assert_equal(deadline, request['trace']['finished_at'], 'Preparation was counted as response time')
    resolution = GameRoomDuckRacing::TraceVerifier.new(challenge: @replay.state[:round][:challenge],
      balances: {0 => 18, 1 => 18}, resources: resources).replay(traces: {0 => request['trace']}, forfeits: [1])
    assert_equal(nil, resolution.settlement.winner)
  ensure
    close
  end

  def numeric_answer
    setup_client('copy_number')
    finish_preparation
    @surface.push(:answer, value: trace.state[:model][:answer])
    advance(@program.now_ms + 500)
    assert_equal(500, request['trace']['finished_at'])
    assert_equal(500, request['trace']['actions'].first['at'])
    assert_equal({correct: true, answer: trace.state[:model][:answer]}, ENGINE.result_for(trace.state, 0))
  ensure
    close
  end

  def delayed_frame
    setup_client('arithmetic')
    advance(7_000)
    assert_equal([7_000], cues.map { |event| event[:at] })
    assert(@client.local_view[:preparing])
    advance(7_000 + ENGINE::COUNTDOWN_MS)
    @surface.push(:answer, value: trace.state[:model][:answer])
    advance(7_400 + ENGINE::COUNTDOWN_MS)
    assert_equal(400, request['trace']['finished_at'], 'A delayed start frame penalized the player')
  ensure
    close
  end

  def count_playback_and_replay
    setup_client('count_ducks')
    @program.durations[GameRoomDuckRacing::ChallengeAudio::QUACK_ASSET] = 385
    2_000.times do
      advance(@program.now_ms + 10)
      break if @client.local_view[:preparing]
    end
    assert(@client.local_view[:preparing], 'Full quack playback never reached preparation')
    end_at = @program.now_ms
    assert_equal(:listening, @client.local_view.dig(:own, :phase))
    assert_equal([], cues)
    assert(@program.sounds.all? { |sound| !sound.playing? }, 'The pause started before the quack tail ended')
    advance(end_at)
    advance(end_at + 2_999)
    assert_equal([], cues)
    advance(end_at + 3_000)
    advance(end_at + ENGINE::COUNT_DUCKS_PREPARATION_MS - 1)
    assert_equal([end_at + 3_000], cues.map { |event| event[:at] })
    assert(@client.local_view[:preparing])
    @surface.push(:answer, value: trace.state[:model][:private][:count])
    advance(end_at + ENGINE::COUNT_DUCKS_PREPARATION_MS)
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    start = end_at + ENGINE::COUNT_DUCKS_PREPARATION_MS
    assert_equal([end_at + 3_000], cues.map { |event| event[:at] })
    deadline = @client.local_view.dig(:own, :deadline_ms)
    assert_equal(start + 20_000, deadline)
    @surface.push(:replay)
    advance(start + 100)
    2_000.times do
      advance(@program.now_ms + 10)
      break unless @audios.first.busy?
    end
    assert_equal(deadline, @client.local_view.dig(:own, :deadline_ms), 'F5 renewed the response clock')
    assert_equal(1, cues.length, 'F5 added a second start cue')
    assert(!@client.local_view[:preparing], 'F5 added another preparation pause')
    @surface.push(:answer, value: trace.state[:model][:private][:count])
    advance(@program.now_ms + 100)
    assert(trace.finished?)
    assert_equal({correct: true}, ENGINE.result_for(trace.state, 0))
  ensure
    close
  end

  def playback_device_boundaries
    [1_700, 4_200].each do |duration|
      setup_client('copy_number')
      @program.durations[GameRoomDuckRacing::ChallengeAudio::COUNTDOWN_ASSET] = duration
      advance(ENGINE::PREPARATION_DELAY_MS)
      advance(ENGINE::PREPARATION_DELAY_MS + duration - 1)
      assert(@client.local_view[:preparing], 'Nominal duration ended a still-playing recording')
      advance(ENGINE::PREPARATION_DELAY_MS + duration)
      assert(!@client.local_view[:preparing])
      @surface.push(:answer, value: trace.state[:model][:answer])
      advance(ENGINE::PREPARATION_DELAY_MS + duration + 100)
      assert_equal(100, request['trace']['finished_at'])
      assert(cues.first[:sound].closed?, 'The completed countdown retained its audio handle')
      close
    end
    setup_client('copy_number')
    @program.missing = true
    advance(ENGINE::PREPARATION_DELAY_MS)
    assert_equal('cancel', request['action'], 'A missing cue silently started the timed challenge')
    assert_equal(false, trace.finished?)
    close
    setup_client('copy_number')
    advance(ENGINE::PREPARATION_DELAY_MS)
    cues.first[:sound].stalled = true
    advance(ENGINE::PREPARATION_MS + 2_000)
    assert_equal('cancel', request['action'], 'A stalled cue waited forever')
    assert_equal(false, trace.finished?)
    assert(cues.first[:sound].closed?)
  ensure
    close
  end

  def covered_and_cancelled
    setup_client('copy_number')
    output = GameRoomSoundOutput.new(@program, audio_game: true, covered: -> { true })
    @program.class.settings = {'background_game_sounds' => 'all'}
    @progress.covered = true
    advance(0, background: true)
    advance(ENGINE::PREPARATION_DELAY_MS, background: true)
    advance(ENGINE::PREPARATION_MS, background: true)
    assert_equal(1, cues.length)
    assert_equal(0, cues.first[:volume])
    advance(ENGINE::PREPARATION_MS + 15_000, background: true)
    assert(trace.finished?)
    @progress.covered = false
    @client.tick
    assert_equal(1, cues.length, 'Returning replayed the starting cue')
    close
    output.close
    setup_client('copy_number')
    advance(1_000)
    @client.update_table_control({'__players' => %w[Alice Replacement Charlie], '__table_owner' => 'Alice'})
    advance(5_000)
    assert_equal(0, cues.length, 'Cancelled preparation played a stale cue')
    assert(@program.sounds.all?(&:closed?))
    assert_equal(nil, request)
  ensure
    output&.close
    @program.class.settings = {}
    close
  end

  def observer
    setup_client('copy_number', viewer: 'Charlie')
    advance(ENGINE::PREPARATION_MS)
    assert_equal([], cues)
    assert_equal(nil, trace)
    assert_equal(false, @surface.presentation[:enabled])
  ensure
    close
  end
end

DuckSpeedPreparationTest.new.run
