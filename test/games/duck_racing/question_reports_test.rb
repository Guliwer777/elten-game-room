require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/quiz_reports'

class DuckQuestionReportsTest
  include DuckClientTest

  def run
    %w[Alice Bob Observer].each do |viewer|
      setup_client('quiz', viewer: viewer)
      game = GameRoomGames::DuckRacing.new
      game.instance_variable_set(:@local_client, WeakRef.new(@client))
      tracker = GameRoomQuizReports::Tracker.new(user: viewer, current_user: -> { viewer })
      data = game.reportable_question(@replay)
      drawn = resources.fetch(:questions).draw(seed: @replay.state[:round][:challenge][:seed])
      assert_equal(@client.local_view[:question][:choices], data['answers'])
      assert_equal(drawn[:choices][drawn[:correct_index]], data['correct'])
      assert_equal(drawn[:set_id], data['set'])
      assert_equal(drawn[:language_id], data['language'])
      assert_equal(false, data.key?('own_answer'))
      tracker.observe(91, data)
      3.times { tracker.observe(91, game.reportable_question(@replay)) }
      assert_equal('There is no previous question to mark.', tracker.mark('previous'))
      tracker.mark('current')
      data['answers'].clear
      assert_equal(4, game.reportable_question(@replay)['answers'].size)
      replace do |replay|
        replay.state[:round][:challenge][:id] = 2
        replay.state[:round][:challenge][:seed] = 77
        replay.state[:race][:challenge][:id] = 2
        replay.state[:race][:challenge][:seed] = 77
      end
      tracker.observe(91, game.reportable_question(@replay))
      tracker.mark('previous')
      assert_equal(1, tracker.questions.size, 'Repeated marking duplicated the same question')
      assert_equal(1, tracker.questions.first['position'])
      old = Marshal.load(Marshal.dump(@replay))
      old.state[:round][:challenge][:id] = 1
      assert_equal(nil, game.reportable_question(old), 'Old replay captured a newer question')
      close
      assert_equal(nil, game.reportable_question(@replay), 'Closed client exported a question')
    end
    setup_client('quiz', phase: :preparing)
    assert_equal(nil, @client.reportable_question(@replay), 'Preparation marked an unseen question')
    close
    setup_client('copy_number')
    assert_equal(nil, @client.reportable_question(@replay), 'Non-quiz challenge exposed a report')
    close
    report('Duck question reports: actual shuffled question, previous, spectators, lifecycle')
  ensure
    close
  end
end
DuckQuestionReportsTest.new.run
