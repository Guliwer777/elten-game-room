# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_preview'
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
Form.prepend(TournamentPublicUI::Script)
T=TournamentPublicUI
def actions(form)
  form.fields.first
end
def choose(form,label)
  list=actions(form)
  index=list.options.index(label)
  raise "Missing action: #{label}" unless index
  form.index=form.fields.index(list)
  list.index=index
  list.trigger(:select)
end
def preview(snapshot,**options)
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot,clock:-> {150},**options))
end
snapshot=T.snapshot([T.publication,T.publication(22)],[T.registration(31),T.registration(32,tournament_id:22,user:'Obcy')])
before=Marshal.dump(snapshot)
T.script(->(form){
  list=actions(form)
  assert(list.is_a?(ListBox) && form.index==0,'Entry must focus the actions list')
  assert(list.header.include?('Łódź') && list.header.include?('Registration open'))
  assert(!list.header.include?('Żółć'),'Rules clutter the action header')
  assert(!list.header.include?('Obcy') && !list.header.include?('settings_json'))
  assert(form.accept_button.nil?,'Reading details consented to membership')
  assert(!actions(form).options.include?('Join tournament'),'Registered player still has Join')
  choose(form,'Information and rules')
  form.cancel_button.trigger(:press)
},->(form){
  content=form.fields.first.text
  local_start=Time.utc(2026,10,15,18).getlocal.strftime('%Y-%m-%d %H:%M')
  assert(content.include?('Żółć') && content.include?(local_start),content)
  form.cancel_button.trigger(:press)
}){preview(snapshot).wait}
assert_equal(before,Marshal.dump(snapshot))
variants = [['chess', {}], ['three_five_eight', {}], ['rummy', { 'elimination' => true, 'score_limit' => 1700 }],
  ['mille_bornes', {}], ['mille_bornes', {'include_safeties' => false, 'custom_deck' => true}], ['duck_racing', {}]]
quiz = GameRoomGames::CATALOG.build('quiz')
languages = quiz.effective_option_definitions({}).find { |definition| definition.key == GameRoomContent::LANGUAGE_OPTION_KEY }.choices
languages.each do |language|
  selected = { GameRoomContent::LANGUAGE_OPTION_KEY => language.value }
  sets = quiz.effective_option_definitions(selected).find { |definition| definition.key == GameRoomContent::SET_OPTION_KEY }.choices
  variants << ['quiz', selected.merge(GameRoomContent::SET_OPTION_KEY => sets.last.value)]
end
variants.each do |game_id, input_options|
  snapshot = T.snapshot([T.publication(game: game_id, options: input_options, 'format' => 'groups_knockout', 'rematch' => true, 'pairing' => 'balanced_cycle')])
  game = GameRoomGames::CATALOG.build(game_id)
  options = JSON.parse(snapshot['announcements'].first['settings_json']).fetch('game_options')
  before = Marshal.dump(snapshot)
  T.script(lambda do |form|
    content = GameRoomTournaments::PublicText.new(registry:GameRoomGames::CATALOG,mode_label:T::MODE,actor:T::ACTOR).description(snapshot['announcements'].first,snapshot)
    assert(content.include?('Groups and knockout') && content.include?('Return matches: Yes') && content.include?('Rotating compositions'), 'Pominięto wariant turnieju')
    game.effective_option_definitions(options).each do |definition|
      label = GameRoomContent.utf8(definition.summary_label || definition.label)
      unless game.option_visible?(definition, options, normalize: false)
        assert(!content.include?(label + ': '), 'Pokazano nieaktywną opcję zależną')
        next
      end
      value = options.fetch(definition.key.to_s, definition.default)
      expected = case definition.kind.to_sym
      when :boolean then value ? 'Yes' : 'No'
      when :choice then definition.choices.find { |choice| choice.value.to_s == value.to_s }.label
      when :multiple_choice
        labels = definition.choices.each_with_index.filter_map { |choice, index| choice.label if (value & (1 << index)) != 0 }
        labels.empty? ? 'None' : labels.join(', ')
      when :multiple_values
        labels = definition.choices.filter_map { |choice| choice.label if value.include?(choice.value) }
        labels.empty? ? 'None' : labels.join(', ')
      else
        definition.summary_unit == :seconds ? "#{value} seconds" : value.to_s
      end
      assert(content.include?("#{label}: #{expected}"), "Brak etykiet opcji #{game_id}/#{definition.key}: #{expected}")
    end
    form.cancel_button.trigger(:press)
  end) { GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot)).wait }
  assert(Marshal.dump(snapshot) == before, 'Formatowanie opcji zmieniło wejście')
end
puts 'PASS actual option forms: chess, 3-5-8, Rummy, compact Mille Bornes defaults/custom deck, Duck checklists, Quiz languages and sets'


initial=T.snapshot([T.publication.merge('timezone'=>'UTC')])
{'confirmed'=>'Registration confirmed.','prepared'=>'Registration not confirmed.','attempted'=>'Registration not confirmed.',
 'outside_window'=>'Registration outside the allowed window.','conflict'=>'Conflict — registration was not sent again.',
 nil=>'Registration not confirmed.'}.each do |status,message|
  writes,alerts,reads=[],[],0
  dialog=nil
  T.script(->(form){
    choose(form,'Join tournament')
    assert_equal([11],writes)
    assert(T.field(form,'Status').text.include?(message))
    assert_equal(1,reads)
    assert(!actions(form).options.include?('Join tournament'),'Uncertain/committed write exposed retry')
    dialog.send(:request_join)
    assert_equal([11],writes,'Repeated input resubmitted an uncertain join')
    assert_equal([],dialog.snapshot['members'],'Write response fabricated membership')
    form.cancel_button.trigger(:press)
  }){
    dialog=preview(initial,join:->(id){writes<<id;status && T.record(status)},load:->{reads+=1;nil},alert:->(m){alerts<<m})
    dialog.wait
  }
end
member=T.snapshot([T.publication],[T.registration(51,user:'ŻANETA')])
[T::ACTOR,'ŻANETA'.b.freeze].each do |actor|
  T.script(->(form){
    assert(!actions(form).options.include?('Join tournament'))
    form.cancel_button.trigger(:press)
  }){preview(member,actor:actor).wait}
end
fresh=T.snapshot([T.publication],[T.registration(81)])
T.script(->(form){
  choose(form,'Join tournament')
  assert(!actions(form).options.include?('Join tournament'))
  form.cancel_button.trigger(:press)
}){preview(initial,load:->{fresh},join:->(_){T.record('confirmed')},alert:->(*){}).wait}
# Missing/conflicting publications, changed canonical identity, and a failed
# refresh must never turn an old snapshot into permission to write.
row=T.publication.merge('timezone'=>'UTC')
cached=initial['announcements'].first
[
 T.snapshot([]),T.snapshot([row,row.merge('rules'=>'Conflicting')]),
 T.snapshot([row.merge('publication_key'=>'another-key')]),
 T.snapshot([row.merge('__insertion_user'=>'Another organizer')]),
 T.snapshot([row,row.merge('__id'=>7)])
].each do |current|
  dialog=nil
  T.script(->(form){
    description=actions(form).header
    assert(T.field(form,'Status').text.include?('Outdated preview'))
    assert(!actions(form).options.include?('Join tournament'))
    choose(form,'Refresh')
    assert_equal(description,actions(form).header)
    dialog.send(:request_join)
    form.cancel_button.trigger(:press)
  }){
    dialog=preview(current,publication:cached,load:->{nil},join:->(*){raise 'Stale join'},alert:->(*){})
    dialog.wait
  }
end
# Reentrant UI pumping during writes/reads must not submit or close twice.
instance=parent=nil
calls=[]
reenter=->{
  instance.wait
  actions(parent).trigger(:select)
  parent.cancel_button.trigger(:press)
}
T.script(->(form){
  parent=form
  choose(form,'Join tournament')
  assert_equal([:join,:load],calls)
  assert_equal(form.fields.index(actions(form)),form.index)
  form.cancel_button.trigger(:press)
}){
  instance=preview(initial,join:->(_){calls<<:join;reenter.call;T.record('attempted')},
    load:->{calls<<:load;reenter.call;nil},alert:->(*){reenter.call})
  instance.wait
}
['unconfirmed','failed','',nil].each do |unknown|
  T.script(->(form){
    error=assert_raises(ArgumentError){choose(form,'Join tournament')}
    assert(error.message.include?('Unexpected tournament join status'))
    form.cancel_button.trigger(:press)
  }){preview(initial,join:->(_){T.record(unknown)}).wait}
end
[ArgumentError.new('bug'),NoMethodError.new('method bug')].each do |failure|
  T.script(->(form){
    assert_equal(failure,assert_raises(failure.class){choose(form,'Refresh')})
    form.cancel_button.trigger(:press)
  }){preview(initial,load:->{raise failure}).wait}
end
[nil,'','   ',42].each do |value|
  assert_raises(ArgumentError){preview(initial,mode_label:value)}
  assert_raises(ArgumentError){preview(initial,actor:value)}
end
puts 'PASS concise dashboard, separate rules/options, contextual actions, uncertain writes, fresh membership, Unicode, stale identity, reentry and programmer errors'
