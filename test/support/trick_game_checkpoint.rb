require_relative 'tournament_forfeit_native'
require_relative 'private_card_games'

module TrickGameCheckpointTest
  module_function

  def checkpoint(h, user = h.users.first)
    h.game.tournament_scored_checkpoint(h.replay(user), options: h.replay(user).state[:options])
  end

  def play_round(h, runners, surrender: false)
    120.times do
      replay = h.replay(h.users.first)
      return replay if [:round_complete, :finished, :private_error].include?(replay.state[:phase])
      if replay.state[:phase].to_s.start_with?('private_') || replay.state[:phase] == :awaiting_deal
        PrivateCardGamesTest.tick(h, runners)
        next
      end
      actor = replay.current_player
      choices = h.game.legal_actions(h.replay(actor), actor)
      action = choices.find { |item| item['action'] == 'surrender' } if surrender
      action ||= choices.find { |item| item['action'] != 'surrender' }
      assert(action, "#{h.game.id}: no legal action in #{replay.state[:phase]}")
      PrivateCardGamesTest.submit(h, runners, actor, action)
    end
    raise "#{h.game.id}: no completed deal within the legal action budget"
  end

  def verify_boundary(h, runners, surrender: false)
    assert_equal({'status'=>'none'}, checkpoint(h), 'Unplayed deal is not a scored checkpoint')
    finished = play_round(h, runners, surrender: surrender)
    assert_equal(:round_complete, finished.state[:phase], "#{h.game.id}: failed round #{finished.state[:private_error]}")
    assert_equal(h.events(h.users.first).size, finished.accepted_events.size)
    expected = {'status'=>'scored', 'event_id'=>finished.accepted_events.last['__id'],
      'index'=>1, 'kind'=>'deal', 'order'=>'higher', 'scores'=>finished.state[:scores].dup}
    assert_equal(expected, checkpoint(h))
    assert_equal({'status'=>'cannot_continue'}, h.game.tournament_forfeit_continuation(finished,
      losing_unit: h.users.last, options: finished.state[:options]))
    h.users.each { |user| assert_equal(expected, checkpoint(h, user), 'Viewer changed public checkpoint') }
    old_scores = expected['scores'].dup
    16.times { PrivateCardGamesTest.tick(h, runners) }
    assert_equal(2, h.replay(h.users.first).state[:round], 'Next real deal was not started')
    assert_equal(expected, checkpoint(h), 'Partial next deal replaced the completed checkpoint')
    assert_equal(old_scores, expected['scores'], 'New deal mutated the earlier score copy')
    expected
  end
end
