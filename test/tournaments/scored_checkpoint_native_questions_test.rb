require_relative '../support/ui'
require_relative '../support/clock_event_contract'
require_relative '../../games/catalog'

def checkpoint(f)
  f.game.tournament_scored_checkpoint(f.replay,options:f.game.default_options)
end

ClockEventContract.with_server_time do |set_time|
  f=ClockEventContract::Fixture.new(GameRoomGames::QuizParty.new,options:{'target_score'=>100})
  assert_equal({'status'=>'none'},checkpoint(f))
  completed=nil
  4.times do |index|
    r=f.replay
    set_time.call([Time.now.to_i,r.state[:resume_at].to_i].max)
    if r.state[:phase]==:drawing
      f.submit('Alice')
      r=f.replay
      chooser=f.game.send(:current_chooser,r.state)
      f.submit(chooser,{'kind'=>'question','action'=>'submit',
        'question_id'=>f.game.send(:category_surface_id,r.state),'answer'=>r.state[:choices].first})
    end
    f.submit('Alice')
    f.h.users.each do |user|
      state=f.replay(user).state
      f.submit(user,{'kind'=>'question','action'=>'submit',
        'question_id'=>f.game.send(:question_surface_id,state),
        'answer'=>f.game.send(:correct_option_index,state).to_s})
    end
    f.submit('Alice',nil,control:true)
    f.h.users.each { |user| f.submit(user) }
    f.submit('Alice',nil,control:true)
    r=f.replay
    if index<2
      assert_equal({'status'=>'none'},checkpoint(f),'One or two answers were mistaken for a completed round')
    elsif index==2
      completed=checkpoint(f)
      assert_equal('scored',completed['status'])
      assert_equal(r.state[:scores],completed['scores'])
      assert_equal(1,completed['index'])
      assert_equal(f.snapshot.events.last['__id'],completed['event_id'])
    else
      assert(r.state[:scores]!=completed['scores'],'Fourth question did not actually change current scores')
      assert_equal(completed,checkpoint(f),'Partial next round replaced the scored checkpoint')
    end
    f.h.users.each do |user|
      assert_equal(checkpoint(f),f.game.tournament_scored_checkpoint(f.replay(user),options:f.game.default_options))
    end
  end
end

ClockEventContract.with_server_time do |set_time|
  f=ClockEventContract::Fixture.new(GameRoomGames::Categories.new,options:{
    'category_set'=>'custom','custom_categories'=>%w[country city],
    'round_category_count'=>2,'round_time'=>10,'target_score'=>100})
  assert_equal({'status'=>'none'},checkpoint(f))
  completed=nil
  2.times do |index|
    set_time.call([Time.now.to_i,f.replay.state[:resume_at].to_i].max)
    f.submit('Alice')
    state=f.replay.state
    f.h.users.reject { |user| user==state[:judge] }.each do |user|
      answers=state.fetch(:round_categories).to_h { |key| [key,"#{state[:letter]}#{user}#{key}"] }
      f.submit(user,{'kind'=>'answer_sheet','action'=>'submit','answers'=>answers})
    end
    f.submit('Alice',nil,control:true)
    f.h.users.reject { |user| user==state[:judge] }.each { |user| f.submit(user) }
    f.submit('Alice',nil,control:true)
    r=f.replay
    spec=f.game.surface_spec(r,r.state[:judge])
    spec=spec.parts.first.surface if spec.is_a?(GameSurfaces::CompositeSpec)
    decisions=spec.items.to_h { |item| [item.id,'unique'] }
    f.submit(r.state[:judge],{'kind'=>'review','action'=>'finish','decisions'=>decisions})
    f.submit('Alice',nil,control:true)
    snapshot=f.snapshot
    events=snapshot.events
    prefix=events[0...-1]
    assert_equal('round_finished',events.last['action'])
    partial=f.game.replay(snapshot.session,prefix,f.h.repositories.fetch('Alice'))
    assert_equal(prefix.length,partial.accepted_events.length,'Partial native batch was not valid replay')
    assert_equal(index,partial.state[:completed_rounds])
    expected=index.zero? ? {'status'=>'none'} : completed
    assert_equal(expected,f.game.tournament_scored_checkpoint(partial,options:f.game.default_options),
      'Per-player score rows were mistaken for a fully scored round')
    completed=checkpoint(f)
    assert_equal(index+1,completed['index'])
    assert_equal(f.replay.state[:scores],completed['scores'])
    assert(completed['scores'].values.any?(&:positive?),'Fixture did not award actual reviewed scores')
    assert_equal('continue',f.game.tournament_forfeit_continuation(f.replay,losing_unit:'Alice',options:f.game.default_options)['status'],
      'Categories must continue while two other players remain')
  end
end
puts 'PASS native scored checkpoints: Quiz full three-question boundary and later partial round; Categories all score rows plus round-finish boundary; no fabricated terminal continuation'
