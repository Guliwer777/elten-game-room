require_relative 'client_helpers'

class DuckCompactClientTest
  include DuckClientTest

  def make_replay(kind, **options)
    replay = super
    state, round = replay.state, replay.state[:round]
    state[:challenge_flow] = 2
    if round[:phase] == :playing || ENGINE::INDEPENDENT.include?(kind)
      round.merge!(private: nil, results: nil, attempts: nil, engine: nil)
      GameRoomDuckRacing::Session.send(:begin_challenge, state, {'session' => 91}, 100_000 - @late.to_i, resources)
    end
    replay
  end

  def run
    independent
    local_completion
    private_choices
    shared_readiness
    common_start
    report('Streamlined challenge client: independent practice, compact results, readiness and common cue')
  end

  def independent
    %w[simon rhythm hit_duck].each do |kind|
      setup_client(kind, phase: :preparing)
      assert(@client.local_view[:practice])
      assert_equal(nil, @client.instance_variable_get(:@trace))
      @surface.push(:ready)
      advance(20)
      first = @client.instance_variable_get(:@trace)
      assert(first, "#{kind} still waits for the other player")
      assert_equal({}, @replay.state[:round][:ready])
      assert_equal(nil, request, 'Local Enter wrote a ready event')
      @surface.push(:ready)
      advance(40)
      replace { |replay| replay.state[:round][:last_seen][1] += 1 }
      assert_equal(first, @client.instance_variable_get(:@trace), 'Other player activity restarted the attempt')
      assert_equal([], first.instance_variable_get(:@actions), 'Independent attempt still records a trace')
      close
    end
  ensure
    close
  end

  def local_completion
    setup_client('simon', phase: :preparing)
    @surface.push(:ready)
    advance(20)
    500.times do
      advance(@program.now_ms + 10)
      break if @client.local_view.dig(:own, :phase) == :responding
    end
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    trace = @client.instance_variable_get(:@trace)
    expected = trace.state[:model][:private][:sequence].first
    @surface.push(:tone, value: expected % 5 + 1)
    advance(@program.now_ms + 20)
    assert_equal({'score' => [0, 1]}, request['trace'])
    saved = request
    @surface.push(:ready)
    advance(@program.now_ms + 20)
    assert_equal(saved, request)
    replace { |replay| replay.state[:round][:results][0] = {score: 0} }
    assert_equal(nil, request, 'Accepted local result was sent twice')
    assert(@client.local_view.dig(:own, :done))
    advance(@program.now_ms + 31_000)
    assert_equal(nil, request, 'A finished player kept sending alive records')
  ensure
    close
  end

  def private_choices
    {'rock_paper_scissors' => [:choose, 'paper'], 'quiz' => [:answer, 2]}.each do |kind, (action, value)|
      setup_client(kind)
      @surface.push(action, value: value)
      advance(20)
      key = kind == 'quiz' ? 'answer' : 'choice'
      assert_equal({key => value}, request['trace'])
      close
    end
    setup_client('guess_number', phase: :preparing)
    assert(!@client.local_view[:practice], 'Guessing gained an unnecessary Enter prompt')
    trace = @client.instance_variable_get(:@trace)
    target = trace.state[:model][:answer]
    @surface.push(:answer, value: target)
    advance(20)
    assert_equal({'guesses' => [target]}, request['trace'])
  ensure
    close
  end

  def shared_readiness
    %w[sound_memory audio_ball axel_pong].each do |kind|
      setup_client(kind, phase: :preparing)
      @surface.push(:ready)
      advance(20)
      assert(@client.local_view[:practice])
      assert(@surface.presentation[:instruction].include?('Bob'), 'Waiting message does not identify the missing player')
      @surface.push(:ready)
      advance(40)
      replace do |replay|
        [0, 1].each do |seat|
          assert(GameRoomDuckRacing::Session.apply(replay.state, {'action' => 'ready', 'challenge' => 1,
            'fingerprint' => FINGERPRINT, 'session' => 91}, seat: seat, moderator: false,
            now_ms: 100_040, resources: resources))
        end
      end
      assert_equal(:playing, @replay.state[:round][:phase])
      assert_equal(nil, GameRoomDuckRacing::Session.automatic(@replay.state, now_ms: 100_040))
      close
    end
  ensure
    close
  end

  def common_start
    %w[copy_number arithmetic race_question sound_order count_ducks].each do |kind|
      [0, 650].each do |late|
        @late = late
        setup_client(kind)
        2_000.times do
          advance(@program.now_ms + 10)
          break if !@client.local_view[:preparing] && @program.events.any? { |event| event[:asset] == 'duck_countdown' }
        end
        cue = @program.events.find { |event| event[:asset] == 'duck_countdown' }
        assert(cue, "Missing common cue for #{kind}")
        response = @replay.state[:round][:response_at] || @replay.state[:round][:started_at] + ENGINE::ORDER_PREPARATION_MS
        assert((cue[:at] + 100_000 - (response - ENGINE::COUNTDOWN_MS)).abs <= 10,
          "#{kind} scheduled the cue from receipt time instead of shared time")
        if ENGINE::FIRST_ANSWER.include?(kind)
          trace = @client.instance_variable_get(:@trace)
          answer = kind == 'count_ducks' ? trace.state[:model][:private][:count] : trace.state[:model][:answer]
          @surface.push(:answer, value: answer)
          advance(@program.now_ms + 30)
          assert(request, "No answer after common cue: #{kind}")
        end
        close
      end
    end
  ensure
    @late = nil
    close
  end
end

DuckCompactClientTest.new.run
