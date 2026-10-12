# frozen_string_literal: true

require_relative 'client_helpers'

class DuckClientPromptTest
  include DuckClientTest

  def run
    %w[quiz copy_number arithmetic race_question].each { |kind| prompt_once(kind) }
    answered_projection
    %w[copy_number arithmetic race_question count_ducks].each do |kind|
      setup_client(kind)
      view = @client.local_view.merge(own: {done: true})
      assert_equal('Answer sent.', GameRoomDuckRacing::ChallengePresentation.phase_status(view, true, true, nil, 0))
      close
    end
    report('Duck challenge prompts: initial speech, refresh deduplication, repeated challenges and answered projection')
  end

  def prompt_once(kind)
    $spoken_messages.clear
    setup_client(kind)
    prompt = GameRoomDuckRacing::ChallengePresentation.prompt(kind, @client.local_view)
    assert(!prompt.empty?)
    if %w[arithmetic race_question].include?(kind)
      prompt = "#{prompt} #{GameRoomDuckRacing::ChallengePresentation.digit_hint(kind, @client.local_view)}"
    end
    assert_equal([prompt], $spoken_messages, "#{kind}: its task exists only in the quiet field caption")
    original = $spoken_messages.dup
    4.times do |index|
      replace { |replay| replay.state[:round][:last_seen][1] += index + 1 }
      advance(@program.now_ms + 1)
    end
    assert_equal(original, $spoken_messages, "#{kind}: a refresh repeated the prompt")

    # The same question can be drawn in a later challenge. Its new identity
    # must announce it again even though the text happens to be identical.
    @replay = make_replay(kind, id: 2)
    @replay.state[:revision] = 10
    @client.before_wait(@replay, @viewer)
    assert_equal([prompt, prompt], $spoken_messages)
  ensure
    close
  end

  def answered_projection
    replay = make_replay('quiz')
    # Test the public projection used by an already committed client;
    # it must not imply that the already submitted answer can be changed.
    engine = ENGINE.start(replay.state[:round][:challenge], resources: resources)
    view = ENGINE.view(engine, seat: 0).merge(own: {done: true})
    result = GameRoomDuckRacing::ChallengePresentation.project(kind: 'quiz', view: view, viewer: 0)
    assert_equal('', result[:announcement])
    assert(result[:header].include?(view[:question][:prompt]))
  end
end

DuckClientPromptTest.new.run
