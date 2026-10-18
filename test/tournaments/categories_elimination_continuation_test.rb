require_relative '../support/tournament_elimination_model'
require_relative '../../games/categories'

check = TournamentEliminationModel.method(:assert)
build = -> {
  TournamentEliminationModel::Fixture.new(GameRoomGames::Categories.new,
    options:{'category_set'=>'custom', 'custom_categories'=>%w[country city],
      'round_category_count'=>2, 'target_score'=>10})
}
answer = ->(f, actor, country, city) {
  f.perform(actor, GameSurfaces::Action.new(kind:'answer_sheet', name:'submit',
    payload:{'answers'=>{'country'=>country, 'city'=>city}}))
}
review = ->(f) {
  surface = f.game.surface_spec(f.replay, f.replay.state[:judge])
  surface.is_a?(GameSurfaces::CompositeSpec) ? surface.parts.map(&:surface).find { |s| s.is_a?(GameSurfaces::ReviewSpec) } : surface
}
assess = ->(f) {
  judge = f.replay.state[:judge]
  decisions = {}
  review.call(f).items.each do |item|
    decision = item.decision_ids.include?('unique') ? 'unique' : 'duplicate'
    decisions[item.id] = decision
    unless f.replay.state[:decisions][item.id] == decision
      f.perform(judge, GameSurfaces::Action.new(kind:'review', name:'change', payload:{'item_id'=>item.id, 'decision'=>decision}))
    end
  end
  f.perform(judge, GameSurfaces::Action.new(kind:'review', name:'finish', payload:{'decisions'=>decisions}))
  f.automatic
}

f = build.call
check.call(f.game.validation_error(f.options, player_count:4).nil?, 'valid options required')
f.refuse('Alice', 'tournament_elimination', '[1]')
f.automatic
%w[Bob Carol Dave].each { |actor| answer.call(f, actor, actor, 'shared') }
round = f.game.send(:round_id, f.replay.state)
before = f.replay.state[:commitments].dup
f.refuse('Alice', 'tournament_elimination', '[2]')
f.game.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol', commitment:before['Carol']), 'unaccepted elimination erased answer')
f.eliminate('Carol')
f.assert_roster(%w[Alice Bob Dave])
check.call(f.replay.state[:active_players] == %w[Bob Dave], 'answer roster still includes removed player')
check.call(f.replay.state[:answer_cleanup][:receipts].fetch(round) == {'carol'=>before['Carol']}, 'only departed commitment may be cleaned')
f.game.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol', commitment:before['Carol']).nil?, 'departed answer retained')
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Bob', commitment:before['Bob']), 'active secret lost')
newer = f.vault.prepare(session_id:71, round_id:round, user:'Carol', payload:{'country'=>'Uncertain new generation'})
other = f.vault.prepare(session_id:72, round_id:round, user:'Carol', payload:{'country'=>'Other session'})
GameRoomGames::Categories.new.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol').commitment == newer.commitment, 'new uncertain generation erased')
check.call(f.vault.reveal(session_id:72, round_id:round, user:'Carol').commitment == other.commitment, 'other session erased')
f.automatic
%w[Bob Dave].each { |actor| f.automatic(actor) }
f.automatic
assess.call(f)
check.call(f.replay.state[:scores] == {'Alice'=>0, 'Bob'=>3, 'Carol'=>0, 'Dave'=>3}, 'remaining duplicate/unique scoring changed')
check.call(f.game.tournament_scored_checkpoint(f.replay, options:f.options)['status'] == 'scored', 'completed checkpoint missing')
f.now = f.replay.state[:resume_at]
f.automatic
check.call(f.replay.state[:judge] == 'Bob' && f.replay.state[:active_players] == %w[Alice Dave], 'next judge/roster not projected')
f.assert_cold

# The judge's accepted elimination cancels only the unfinished round. It does
# not invent completed points, and the next judge uses original seat order.
f = build.call
f.automatic
answer.call(f, 'Bob', 'one', 'two')
f.eliminate('Alice')
check.call(f.replay.state[:phase] == :round_complete && f.replay.state[:completed_rounds] == 0, 'judge elimination must cancel unfinished round')
check.call(f.game.tournament_scored_checkpoint(f.replay, options:f.options)['status'] == 'none', 'cancel fabricated checkpoint')
check.call(f.replay.state[:scores].values.all?(&:zero?), 'cancel awarded points')
f.now = f.replay.state[:resume_at]
f.automatic
check.call(f.replay.state[:judge] == 'Bob' && f.replay.state[:active_players] == %w[Carol Dave], 'cancel did not continue')
f.assert_roster(%w[Bob Carol Dave])

# In review, removing one member of a duplicate group invalidates the old
# assessment. A partially emitted score plan is rolled back before regrading.
f = build.call
f.automatic
%w[Bob Carol Dave].each { |actor| answer.call(f, actor, actor, 'shared') }
f.automatic
%w[Bob Carol Dave].each { |actor| f.automatic(actor) }
f.automatic
judge = f.replay.state[:judge]
decisions = review.call(f).items.to_h { |item| [item.id, item.decision_ids.include?('unique') ? 'unique' : 'duplicate'] }
f.perform(judge, GameSurfaces::Action.new(kind:'review', name:'finish', payload:{'decisions'=>decisions}))
status, plan = f.game.action_for(f.game.automatic_action(f.replay, judge, context:f.context), f.replay, judge, context:f.context)
check.call(status == :ok && plan.events.length > 1, 'real partial scoring plan required')
command = plan.events.first
f.append(judge, command.action, command.value)
check.call(f.replay.state[:scores].values.any?(&:positive?), 'partial score not created')
f.eliminate('Carol')
check.call(f.replay.state[:scores].values.all?(&:zero?), 'partial score not rolled back')
check.call(!f.replay.state[:review_finished], 'changed duplicate group kept final assessment')
assess.call(f)
check.call(f.replay.state[:scores] == {'Alice'=>0, 'Bob'=>3, 'Carol'=>0, 'Dave'=>3}, 'reassessment doubled partial points')
f.refuse('Alice', 'tournament_elimination', '[2]', '__tournament_elimination'=>true)
f.assert_cold

permanent = TournamentEliminationModel::Fixture.new(GameRoomGames::Categories.new, options:{'judge_mode'=>'master'})
check.call(permanent.game.tournament_forfeit_continuation(permanent.replay, losing_unit:'Bob', options:permanent.options)['status'] == 'unsupported', 'noncompetitive judge mode must stay unsupported')
puts 'Categories tournament elimination: answerer, judge, partial review, cleanup and fixed seats OK'
