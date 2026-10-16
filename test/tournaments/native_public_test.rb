# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_public_ui'
require_relative '../support/localization'
require_relative '../../lib/tournaments/public_screen'
GameRoomTestLocalization.use_language('en')
T=TournamentPublicUI
LIST='Tournaments'
PREVIEW=/Próba (11|22) — Łódź/

def native_screen(snapshot,**options)
  args=T.arguments(snapshot,**options).reject{|key,_|[:publication,:snapshot].include?(key)}
  GameRoomTournaments::PublicScreen.new(**args,clock:-> {150})
end

def preview(snapshot,**options)
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot,**options),clock:-> {150})
end

def dashboard_action(form,label)
  actions=form.fields.first
  position=actions.options.index(label)
  return false unless position
  actions.index=position
  actions.trigger(:select)
  true
end

def refresh(form)
  form.fields.first.header==LIST ? T.button(form,'Refresh').press : dashboard_action(form,'Refresh')
end

def presentation(field,item=nil)
  header=field.header || field.label
  [SpeechOutput.calls.last&.first,NVDA.calls.last&.first].each do |value|
    assert(value.to_s.start_with?(header),"Wrong native focus: #{value.inspect}, expected #{header}")
    assert(value.include?(item),'Wrong selected row announced') if item
  end
end

# Opening the action list never enrolls. Enter on Join is explicit consent;
# a failed readback must not permit a duplicate.
driver=TournamentNativeDriver.new
snapshot=T.snapshot([T.publication,T.publication(22)])
original=Marshal.dump(snapshot)
calls=[]
driver.press(LIST,40)
driver.step(LIST,[13])
driver.step(PREVIEW,[13]) do |form|
  assert(calls.empty?,'Opening actions joined the tournament')
  assert(form.index==0 && form.fields.first.options.first=='Join tournament','Entry did not focus the first available action')
  assert(form.accept_button.nil?,'The form has an implicit Join outside the actions list')
end

driver.step(PREVIEW) do |form|
  assert(calls==[22],'Explicit Join missing or repeated')
  assert(!form.fields.first.options.include?('Join tournament'),'Uncertain readback re-enabled Join')
  assert(T.field(form,'Status').text.include?('Registration confirmed.'),'Confirmation missing')
  presentation(form.fields.first)
end
driver.step(PREVIEW,[27])
driver.step(LIST,[27]) do |form|
  assert(form.index==0 && form.fields.first.index==1,'Return lost table identity or focus')
  presentation(form.fields.first,'Próba 22')
end
reads=0
native_screen(snapshot,load:-> {reads+=1;reads==1 ? snapshot : nil},
  join:->(id){calls<<id;T.record('confirmed',tournament_id:id)},alert:->(*){}).run
driver.finish
assert(Marshal.dump(snapshot)==original,'Input snapshot mutated')
puts 'PASS native directory/actions: opening does not join, explicit consent once and return focus'

# ID retention across reorder/rename, failed reads and an authoritative empty
# list; callbacks pumping a modal cannot repeat the read or exit the parent.
driver=TournamentNativeDriver.new
first,second=T.publication,T.publication(22)
initial=T.snapshot([first,second])
changed=T.snapshot([first,second.merge('title'=>'Zmieniony Łukasz')])
reversed=GameRoomTournaments::Publication::Data.freeze_tree(changed.merge('announcements'=>changed['announcements'].reverse))
loads=[initial,reversed,nil,T.snapshot([])]
parent=nil
reads=0
driver.press(LIST,40)
3.times do |index|
  driver.step(LIST,[13]) do |form|
    parent=form
    form.index=form.fields.index(T.button(form,'Refresh'))
  end
  driver.step(LIST) do |form|
    assert(form.index==form.fields.index(T.button(form,'Refresh')),'Refresh lost focus')
    if index<2
      assert(form.fields.first.index==0 && form.fields.first.options.first.include?('Zmieniony'),'Selected ID was lost')
    else
      assert(form.fields.first.options.empty?,'An authoritative empty list was ignored')
    end
  end
end
driver.step(LIST,[27])
native_screen(initial,load:-> {
  reads+=1
  if parent
    parent.accept_button.press
    T.button(parent,'Refresh').press
    parent.cancel_button.press
    parent.index=1
    parent.fields.first.index=1
  end
  loads.shift
}).run
driver.finish
assert(reads==4,'Reentrant callback repeated a request')
puts 'PASS native refresh: selected ID, renamed/reordered rows, nil vs empty, reentry and focus'

%w[prepared attempted confirmed outside_window conflict].each do |status|
  driver=TournamentNativeDriver.new
  parent=nil
  calls=[]
  reenter=-> {
    dashboard_action(parent,'Join tournament')
    dashboard_action(parent,'Refresh')
    parent.cancel_button.press
  }
  driver.step(PREVIEW,[13]) do |form|
    parent=form
    form.index=form.fields.index(form.fields.first)
  end
  driver.step(PREVIEW,[27]) do |form|
    assert(calls==[:join,:load],'Reentry duplicated Join or Refresh')
    state=T.field(form,'Status').text
    expected=status=='confirmed' ? 'Registration confirmed.' : status=='outside_window' ? 'outside the allowed window' : status=='conflict' ? 'Conflict' : 'not confirmed'
    assert(state.include?(expected),'Incorrect write outcome')
    assert(!form.fields.first.options.include?('Join tournament'),'Write can be repeated without recovery')
  end
  preview(T.snapshot,join:->(_){calls<<:join;reenter.call;T.record(status)},
    load:-> {calls<<:load;reenter.call;nil},alert:->(*){reenter.call}).wait
  driver.finish
end
puts 'PASS native enrollment: confirmed, pending, conflict and expired outcomes, no reentrant writes'

# F1 at every visible field of both redesigned forms. Every phase of help
# focus/resume attempts reentry; the parent must be restored and spoken once.
[LIST,PREVIEW].each do |header|
  origins=header==LIST ? [0,1,4] : [0]
  origins.each do |origin|
    [13,27].each do |key|
      driver=TournamentNativeDriver.new
      parent=screen=help=nil
      calls,events=[],[]
      armed=false
      return_counts=nil
      baseline=header==LIST ? [:load] : []
      reenter=->(event) do
        events<<event
        parent.game_room_hotkey_action(1).call
        screen.public_send(header==LIST ? :run : :wait)
        header==LIST ? parent.accept_button.press : dashboard_action(parent,'Join tournament')
        refresh(parent)
        parent.cancel_button.press
        assert(calls==baseline,"Help reentered the parent at #{event}")
      end
      original_tick=driver.method(:tick)
      driver.define_singleton_method(:tick) do |form|
        original_tick.call(form)
        if form.is_a?(GameRoomUI::Form) && form.fields.first.header=='Keyboard shortcuts' && help.nil?
          help=form
          [:before_focus,:focus].each{|event|form.fields.first.on(event){reenter.call("help_#{event}")}}
        end
      end
      driver.on_resume=->(form) do
        if form.equal?(help)
          reenter.call('help_resume')
          parent.index=header==LIST ? 1 : 0
          parent.fields.first.index=0 if header==LIST
        end
      end
      driver.step(header) do |form|
        parent=form
        form.index=origin
        form.fields.first.index=1 if header==LIST
        carets=form.fields.grep(EditBox).map{|field|field.index,field.check=3,8;[field,field.text.dup,3,8]}
        target=form.fields[origin]
        [:before_focus,:focus].each{|event|target.on(event){reenter.call("parent_#{event}") if armed}}
        armed=true
        form.game_room_hotkey_action(1).call
        armed=false
        assert(form.index==origin,'F1 lost the field')
        assert(form.fields.first.index==1,'F1 lost the selected ID') if header==LIST
        assert(carets.all?{|field,value,index,check|[field.text,field.index,field.check]==[value,index,check]},'F1 changed text or caret')
        assert([SpeechOutput.calls.length-return_counts[0],NVDA.calls.length-return_counts[1]]==[1,1],'F1 did not present the parent exactly once')
        assert(events==%w[help_before_focus help_focus modal help_resume parent_before_focus parent_focus],'Unexpected help focus lifecycle')
        presentation(target,header==LIST && origin==0 ? 'Próba 22' : nil)
      end
      driver.step('Keyboard shortcuts',[key]) do |form|
        assert(form.fields.first.text.include?('F2') && form.fields.first.text.include?('F3'),'Shared volume help missing')
        reenter.call('modal')
        return_counts=[SpeechOutput.calls.length,NVDA.calls.length]
      end
      driver.step(header) do |form|
        refresh(form)
        assert(calls==baseline+[:load],'Help left the parent busy')
      end
      driver.step(header,[27])
      options={load:-> {calls<<:load;T.snapshot([T.publication,T.publication(22)])},
        join:->(_){calls<<:join;nil},alert:->(*){}}
      screen=header==LIST ? native_screen(T.snapshot,**options) : preview(T.snapshot,**options)
      screen.public_send(header==LIST ? :run : :wait)
      driver.finish
      assert(driver.forms.size==2 && driver.resume_counts.values.all?{|count|count==1},'Unexpected modal or repeated close')
    end
  end
end
puts 'PASS native F1: all visible fields, Enter/Escape, guarded modal callbacks, one focus, text/caret and next action'

# Source encoding matches the native loader. Every localized field is checked,
# including list options rather than pretending that every field is an EditBox.
%w[public_text public_preview public_screen].each do |name|
  path=File.expand_path("../../lib/tournaments/#{name}.rb",__dir__)
  TOPLEVEL_BINDING.eval(File.binread(path).sub(/\A# encoding: UTF-8\r?\n/,''),path,2)
end
%w[en pl].each do |language|
  GameRoomTestLocalization.use_language(language)
  label=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
  driver=TournamentNativeDriver.new
  row=T.publication(game:'rummy',options:{'elimination'=>true,'score_limit'=>1700})
  driver.step(label.call(LIST),[13])
  driver.step(PREVIEW,[27]) do |form|
    assert(form.fields.first.header.include?('Łódź'),'Unicode title lost')
    form.fields.each do |field|
      values=field.is_a?(Button) ? [field.label] : field.is_a?(ListBox) ? [field.header,*field.options] : [field.header,field.text]
      assert(values.compact.all?{|value|value.valid_encoding? && value.encoding==Encoding::UTF_8},'Binary UI text is not UTF-8')
    end
  end
  driver.step(label.call(LIST),[27])
  native_screen(T.snapshot([row])).run
  driver.finish
end
GameRoomTestLocalization.use_language('en')
cached=T.snapshot([T.publication])['announcements'].first
current=T.snapshot([T.publication,T.publication.merge('__id'=>7)],[T.registration(93)])
driver=TournamentNativeDriver.new
reads=0
driver.step(PREVIEW) do |form|
  assert(T.field(form,'Status').text.include?('Outdated preview'),'Stale alias not explained')
  assert(form.fields.first.options==['Refresh'],'Stale alias exposes a write')
  dashboard_action(form,'Refresh')
  assert(reads==1 && T.field(form,'Status').text.include?('Refresh failed'),'Failed read not retained')
end
driver.step(PREVIEW,[27])
preview(current,publication:cached,load:-> {reads+=1;nil}).wait
driver.finish
puts 'PASS native binary EN/PL and stale publication aliases: read-only actions and retained failed-read status'
