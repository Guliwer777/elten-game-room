require_relative '../support/tournament_elimination_model'
require_relative '../../lib/game_content'
require_relative '../../content/languages'
require_relative '../../content/quiz_pl_wikidata'
require_relative '../../games/quiz_party'

check = TournamentEliminationModel.method(:assert)
registry = GameRoomContent::Registry.new
GameRoomContent.registry.languages.each { |language| registry.register_language(language) }
registry.register_pack(GameRoomContent.registry.pack('quiz.wikidata.pl'))
build = -> {
  game = GameRoomGames::QuizParty.new
  game.define_singleton_method(:content_registry) { registry }
  TournamentEliminationModel::Fixture.new(game, options:{'answer_time'=>5, 'target_score'=>15})
}
choose = ->(f) {
  actor = f.replay.current_player
  surface = f.game.surface_spec(f.replay, actor)
  f.perform(actor, GameSurfaces::Action.new(kind:'question', name:'submit',
    payload:{'question_id'=>surface.id, 'answer'=>surface.options.first.id}))
}
answer = ->(f, actor, correct) {
  surface = f.game.surface_spec(f.replay, actor)
  index = f.game.send(:correct_option_index, f.replay.state)
  index = (index + 1) % 4 unless correct
  f.perform(actor, GameSurfaces::Action.new(kind:'question', name:'submit',
    payload:{'question_id'=>surface.id, 'answer'=>index.to_s}))
}
finish_question = ->(f) {
  f.automatic
  f.game.tournament_active_players(f.replay, options:f.options).each { |actor| f.automatic(actor) }
  f.automatic
}

f = build.call
f.refuse('Alice', 'tournament_elimination', '[0]')
f.automatic
f.eliminate('Alice')
check.call(f.replay.current_player == 'Bob', 'choosing did not move to next active seat')
choose.call(f)
f.automatic
%w[Bob Carol Dave].each { |actor| answer.call(f, actor, actor == 'Bob') }
round = f.game.send(:question_key, f.replay.state)
commitments = f.replay.state[:commitments].dup
f.refuse('Alice', 'tournament_elimination', '[2]')
f.game.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol', commitment:commitments['Carol']), 'unaccepted elimination erased Quiz answer')
f.eliminate('Carol')
f.game.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol', commitment:commitments['Carol']).nil?, 'Quiz departed secret retained')
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Bob', commitment:commitments['Bob']), 'Quiz active secret removed')
newer = f.vault.prepare(session_id:71, round_id:round, user:'Carol', payload:{'answer'=>'new uncertain'})
other = f.vault.prepare(session_id:72, round_id:round, user:'Carol', payload:{'answer'=>'other session'})
GameRoomGames::QuizParty.new.cleanup_session_answers(f.replay, session_id:71, actors:f.players, hidden_submissions:f.vault)
check.call(f.vault.reveal(session_id:71, round_id:round, user:'Carol').commitment == newer.commitment, 'Quiz new uncertain generation erased')
check.call(f.vault.reveal(session_id:72, round_id:round, user:'Carol').commitment == other.commitment, 'Quiz other session erased')
f.assert_roster(%w[Bob Dave])
finish_question.call(f)
check.call(f.replay.state[:scores] == {'Alice'=>0, 'Bob'=>1, 'Carol'=>0, 'Dave'=>0}, 'score bits compacted original seats')
check.call(f.game.tournament_scored_checkpoint(f.replay, options:f.options)['status'] == 'none', 'single question is not completed round')
check.call(f.replay.history.select { |entry| entry.kind == :answer_result }.map(&:actor) == %w[Bob Dave], 'removed players still counted as wrong answers')
2.times do
  f.now = f.replay.state[:resume_at]
  f.automatic
  answer.call(f, 'Bob', true)
  answer.call(f, 'Dave', false)
  finish_question.call(f)
end
check.call(f.replay.state[:completed_rounds] == 1 && f.game.tournament_scored_checkpoint(f.replay, options:f.options)['scores']['Bob'] == 3, 'round checkpoint missing')
f.now = f.replay.state[:resume_at]
f.automatic
check.call(f.replay.current_player == 'Dave', 'round chooser skipped twice after earlier elimination')
f.assert_cold

# Finish by ordinary questions, never by mutating scores or forcing a winner.
until f.replay.finished?
  choose.call(f) if f.replay.state[:phase] == :choosing
  f.now = [f.now, f.replay.state[:resume_at]].max
  f.automatic
  if f.replay.state[:phase] == :answering
    answer.call(f, 'Bob', true)
    answer.call(f, 'Dave', false)
    finish_question.call(f)
  end
  check.call(f.events.length < 250, 'Quiz continuation did not finish')
end
check.call(f.replay.winner == 'Bob' && f.replay.state[:scores]['Bob'] == 15, 'Quiz natural winner differs')
f.assert_roster(%w[Bob Dave])

# If the chooser leaves during an already selected round, advance only at its
# completion. No questions/choices are retroactively reassigned.
f = build.call
f.automatic
choose.call(f)
f.automatic
f.eliminate('Alice')
3.times do |index|
  unless index.zero?
    f.now = f.replay.state[:resume_at]
    f.automatic
  end
  %w[Bob Carol Dave].each { |actor| answer.call(f, actor, actor == 'Bob') }
  finish_question.call(f)
end
f.now = f.replay.state[:resume_at]
f.automatic
check.call(f.replay.current_player == 'Bob', 'mid-round removal double-advanced chooser')
f.assert_roster(%w[Bob Carol Dave])
puts 'Quiz tournament elimination: chooser/answers, original score bits, cleanup, checkpoints and natural finish OK'
