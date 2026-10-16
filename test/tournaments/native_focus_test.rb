# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_window_fields'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/draft_screen'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })

DRAFTS_HEADER = 'Tournament drafts'.freeze
PREVIEW_HEADER = 'Tournament settings'.freeze

def native_draft(id = 'first')
  { 'id' => id, 'revision' => 1, 'name' => "Tournament #{id}", 'game_id' => 'three_five_eight',
    'game_options' => {}, 'format' => 'round_robin', 'rematch' => false,
    'participants' => %w[Ala Bartek Celina], 'windows' => [], 'players_per_match' => 3, 'pairing' => 'all_combinations' }
end

def assert_native_presentation(header, item = nil)
  speech = SpeechOutput.calls.last&.first.to_s
  braille = NVDA.calls.last&.first.to_s
  assert(speech.start_with?(header) && braille.start_with?(header),
    "FOCUS_REGRESSION: expected #{header.inspect}; speech=#{speech.inspect}; braille=#{braille.inspect}")
  assert(speech.include?(item) && braille.include?(item), 'Native focus announced a different selected row') if item
end

def native_screen(rows)
  forbidden = ->(*) { raise 'Preview invoked a write/configuration/alert callback' }
  GameRoomTournaments::DraftScreen.new(program: Object.new, registry: GameRoomGames::CATALOG,
    load: -> { rows }, persist: forbidden, remove: forbidden, configure: forbidden, alert: forbidden, confirm: forbidden)
end

driver = TournamentNativeDriver.new
rows = [native_draft, native_draft('second')]
before = JSON.generate(rows)
driver.press(DRAFTS_HEADER, 40)
driver.step(DRAFTS_HEADER, [13]) do |form|
  assert(form.fields.first.instance_of?(ListBox) && form.fields.first.index == 1, 'Native Down did not select the second draft')
end
driver.step(PREVIEW_HEADER, [27]) { assert_native_presentation(PREVIEW_HEADER) }
driver.step(DRAFTS_HEADER) do |form|
  assert(form.index == 0 && form.fields.first.index == 1, 'Escape lost the parent field or selected draft')
  assert_native_presentation(DRAFTS_HEADER, 'Tournament second')
end
driver.step(DRAFTS_HEADER, [27])
native_screen(rows).run
driver.finish
assert(JSON.generate(rows) == before && driver.forms.length == 2, 'Preview mutated a draft or opened extra forms')
puts 'PASS native Enter/preview/Escape restores speech and braille to the selected tournament draft'

EDITOR_HEADER = 'Tournament name'.freeze
PARTICIPANTS_HEADER = 'Participants (one name per line; local list)'.freeze
DETAILS_BUTTON = 'Participants and playing windows'.freeze

def native_editor(row)
  forbidden = ->(*) { raise 'Nested settings unexpectedly saved/configured a draft or raised an alert' }
  GameRoomTournaments::DraftEditor.new(program: Object.new, registry: GameRoomGames::CATALOG,
    draft: row, configure: forbidden, save: forbidden, alert: forbidden)
end

driver = TournamentNativeDriver.new
row = native_draft
before = JSON.generate(row)
name = nil
driver.step(EDITOR_HEADER) do |form|
  name = form.fields.first
  name.index, name.check = 2, 7
end
5.times { driver.press(EDITOR_HEADER, 9) }
driver.step(EDITOR_HEADER, [13]) { |form| assert(form.fields[form.index].is_a?(Button) && form.fields[form.index].label == DETAILS_BUTTON, 'Native Tab did not reach the participants button') }
driver.step(PARTICIPANTS_HEADER, [27]) { assert_native_presentation(PARTICIPANTS_HEADER) }
driver.step(EDITOR_HEADER) do |form|
  assert(form.fields[form.index].label == DETAILS_BUTTON, 'Settings changed the editor field')
  assert([name.text, name.index, name.check] == [row['name'], 2, 7], 'Settings changed the name text/caret/selection')
  assert_native_presentation(DETAILS_BUTTON)
end
driver.step(EDITOR_HEADER, [27])
assert(native_editor(row).wait.nil?, 'Cancelled editor returned a draft')
driver.finish
assert(JSON.generate(row) == before && driver.forms.length == 2, 'Settings changed the original draft or opened extra forms')
puts 'PASS native participants/Escape restores editor button speech and braille without changing the draft name selection'

WINDOW_HEADER = 'Start: year'.freeze
WINDOWS_HEADER = 'Playing windows'.freeze

def native_windows
  [3, 4].map do |day|
    { 'date' => "2026-10-0#{day}", 'start' => '18:00', 'end_date' => "2026-10-0#{day}", 'end' => '21:00' }
  end
end

def native_details(row)
  GameRoomTournaments::DraftDetailsEditor.new(program: Object.new, details: row, alert: ->(message) { raise message })
end

driver = TournamentNativeDriver.new
row = native_draft.merge('windows' => native_windows)
before = JSON.generate(row)
participants = windows = participant_state = nil
driver.step(PARTICIPANTS_HEADER) do |form|
  participants, windows = form.fields[0], form.fields[3]
  participants.index, participants.check = 2, 7
  participant_state = [participants.text.dup, participants.index, participants.check]
end
3.times { driver.press(PARTICIPANTS_HEADER, 9) }
driver.press(PARTICIPANTS_HEADER, 40)
2.times { driver.press(PARTICIPANTS_HEADER, 9) }
driver.step(PARTICIPANTS_HEADER, [13]) do |form|
  assert(form.index == 5 && windows.index == 1, 'Native navigation did not reach Edit window for the second row')
end
driver.step(WINDOW_HEADER, [27]) do |form|
  assert_native_presentation(WINDOW_HEADER, '2026')
  assert(TournamentWindowTest.values(form) == ['2026-10-04', '18:00', '2026-10-04', '21:00'], 'Wybierak zgubił datę/godzinę przy otwarciu')
end
driver.step(PARTICIPANTS_HEADER) do |form|
  assert(form.index == 5 && windows.index == 1, 'Window cancellation changed focus/selected row')
  assert([participants.text, participants.index, participants.check] == participant_state, 'Window cancellation changed participants text/caret/selection')
  assert_native_presentation('Edit window')
end
driver.step(PARTICIPANTS_HEADER, [27])
assert(native_details(row).wait.nil?, 'Cancelled settings returned a draft')
driver.finish
assert(JSON.generate(row) == before && driver.forms.length == 2, 'Window cancellation changed the input or opened extra forms')
puts 'PASS native window/Escape restores the previous settings field, row, participants text and selection'

# Native focus hooks and resume's loop_update can dispatch already queued actions.
# Inject events at those exact boundaries, not by replacing Form#focus/wait/resume.
def guard_native_return(driver, parent, action)
  events = []
  exercise_parent = lambda do
    count = driver.forms.length
    2.times do
      parent.cancel_button.press
      parent.accept_button.press
      action.press
    end
    assert(driver.forms.length == count && parent.instance_variable_get(:@wait), 'Reentrant Back/Enter escaped the busy parent')
  end
  [:before_focus, :focus].each do |event|
    parent.fields[parent.index].on(event) do
      assert(Thread.current == driver.ui_thread, 'Focus callback escaped the UI thread')
      events << event
      exercise_parent.call
    end
  end
  driver.on_resume = lambda do |form|
    if form.equal?(parent)
      count = driver.forms.length
      events << :closed
      2.times { parent.cancel_button.press; parent.accept_button.press; action.press }
      assert(driver.forms.length == count, 'Finished parent accepted a delayed action')
    else
      events << :resume
      exercise_parent.call
      2.times { form.cancel_button.press; form.accept_button&.press }
      # Preserve the field from before the modal operation even if another
      # callback navigates the parent during the child's resume pump.
      parent.index = (parent.index + 1) % parent.fields.length
    end
  end
  events
end

def native_button(form, label)
  form.fields.find { |field| field.is_a?(Button) && field.label == label } || raise("Missing button #{label}")
end

[0, 2].each do |origin|
  [:escape, :back].each do |close|
    driver = TournamentNativeDriver.new
    rows = [native_draft, native_draft('second')]
    before = JSON.generate(rows)
    events = status_state = nil
    driver.press(DRAFTS_HEADER, 40)
    origin.times { driver.press(DRAFTS_HEADER, 9) }
    driver.step(DRAFTS_HEADER, [13]) do |form|
      assert(form.index == origin && form.fields.first.index == 1, 'Wrong keyboard preview origin')
      status = form.fields[1]
      status.index, status.check = 2, 7
      status_state = [status.text.dup, status.index, status.check]
      events = guard_native_return(driver, form, form.accept_button)
    end
    if close == :back
      2.times { driver.press(PREVIEW_HEADER, 9) }
      driver.step(PREVIEW_HEADER, [13]) { |form| assert(form.index == 2, 'Native Tab missed Back') }
    else
      driver.step(PREVIEW_HEADER, [27])
    end
    driver.step(DRAFTS_HEADER) do |form|
      assert(form.index == origin && form.fields.first.index == 1, 'Preview did not restore the exact parent field/row')
      status = form.fields[1]
      assert([status.text, status.index, status.check] == status_state, 'Preview changed status text/caret/selection')
      assert(events == [:resume, :before_focus, :focus], 'Preview omitted or duplicated native focus events')
      assert_native_presentation(origin.zero? ? DRAFTS_HEADER : 'View draft', origin.zero? ? 'Tournament second' : nil)
    end
    driver.step(DRAFTS_HEADER, [27])
    native_screen(rows).run
    driver.finish
    assert(events == [:resume, :before_focus, :focus, :closed] && driver.forms.length == 2 && JSON.generate(rows) == before,
      'Preview reentry revived a closed form or changed the drafts')
    puts "PASS native preview origin=#{origin} close=#{close}: focus/resume Back/Enter guard, field, row and text"
  end
end

[0, 5].each do |origin|
  [:cancel, :use].each do |close|
    driver = TournamentNativeDriver.new
    row = native_draft
    before = JSON.generate(row)
    editor = native_editor(row)
    events = name_state = nil
    origin.times { driver.press(EDITOR_HEADER, 9) }
    driver.step(EDITOR_HEADER, origin.zero? ? [] : [13]) do |form|
      name = form.fields.first
      name.set_text('Unsubmitted tournament name')
      name.index, name.check = 2, 7
      name_state = [name.text.dup, name.index, name.check]
      action = native_button(form, DETAILS_BUTTON)
      events = guard_native_return(driver, form, action)
      # The button callback may be invoked with a different focused field;
      # do not fake navigation or replace the native control to test that path.
      action.press if origin.zero?
    end
    driver.step(PARTICIPANTS_HEADER) { |form| form.fields.first.set_text("Ala\r\nBartek\r\nCelina\r\nDarek") }
    if close == :use
      7.times { driver.press(PARTICIPANTS_HEADER, 9) }
      driver.step(PARTICIPANTS_HEADER, [13]) { |form| assert(form.index == 7, 'Native Tab missed Use these settings') }
    else
      driver.step(PARTICIPANTS_HEADER, [27])
    end
    driver.step(EDITOR_HEADER) do |form|
      name = form.fields.first
      expected_index = origin.zero? ? 0 : form.fields.index(native_button(form, DETAILS_BUTTON))
      assert(form.index == expected_index && [name.text, name.index, name.check] == name_state, 'Settings lost previous field/name/selection')
      expected = close == :use ? %w[Ala Bartek Celina Darek] : row['participants']
      assert(editor.instance_variable_get(:@details)['participants'] == expected, 'Settings accepted/discarded the wrong local result')
      assert(events == [:resume, :before_focus, :focus], 'Settings omitted or duplicated native focus events')
      assert_native_presentation(origin.zero? ? EDITOR_HEADER : DETAILS_BUTTON)
    end
    driver.step(EDITOR_HEADER, [27])
    assert(editor.wait.nil?, 'Cancelled editor saved a draft')
    driver.finish
    assert(events == [:resume, :before_focus, :focus, :closed] && driver.forms.length == 2 && JSON.generate(row) == before,
      'Settings reentry changed the original draft or revived a closed editor')
    puts "PASS native settings origin=#{origin} close=#{close}: focus/resume guard and unsubmitted name selection"
  end
end

[:add, :edit].each do |action_kind|
  [:list, :button].each do |origin|
    [:cancel, :use].each do |close|
      driver = TournamentNativeDriver.new
      row = native_draft.merge('windows' => native_windows)
      before = JSON.generate(row)
      editor = native_details(row)
      events = participant_state = window_keys = nil
      expected_index = action_kind == :add && close == :use ? 2 : 1
      origin_index = origin == :list ? 3 : (action_kind == :add ? 4 : 5)
      driver.step(PARTICIPANTS_HEADER) do |form|
        names = form.fields.first
        names.set_text("Unsubmitted name\r\nSecond name")
        names.index, names.check = 2, 7
        participant_state = [names.text.dup, names.index, names.check]
      end
      3.times { driver.press(PARTICIPANTS_HEADER, 9) }
      driver.press(PARTICIPANTS_HEADER, 40)
      (origin_index - 3).times { driver.press(PARTICIPANTS_HEADER, 9) }
      driver.step(PARTICIPANTS_HEADER, origin == :list ? [] : [13]) do |form|
        assert(form.index == origin_index && form.fields[3].index == 1, 'Wrong native window action origin')
        window_keys = form.fields[3].instance_variable_get(:@item_keys).dup
        action = native_button(form, action_kind == :add ? 'Add window' : 'Edit window')
        events = guard_native_return(driver, form, action)
        action.press if origin == :list
      end
      driver.step(WINDOW_HEADER) do |form|
        TournamentWindowTest.fill(form, date: '2026-10-05', start: '19:00', end_date: '2026-10-05', finish: '22:00')
      end
      driver.step(WINDOW_HEADER, [close == :use ? 13 : 27])
      driver.step(PARTICIPANTS_HEADER) do |form|
        names, windows = form.fields[0], form.fields[3]
        assert(form.index == origin_index && windows.index == expected_index, 'Window return lost previous field/selected window')
        assert([names.text, names.index, names.check] == participant_state, 'Window return changed participants text/caret/selection')
        expected_windows = native_windows
        if close == :use
          changed = { 'date' => '2026-10-05', 'start' => '19:00', 'end_date' => '2026-10-05', 'end' => '22:00' }
          action_kind == :add ? expected_windows.push(changed) : expected_windows[1] = changed
        end
        assert(editor.instance_variable_get(:@details)['windows'] == expected_windows, 'Window return changed the accepted/cancelled result')
        keys = windows.instance_variable_get(:@item_keys)
        assert(keys.take(2) == window_keys && keys.uniq.length == expected_windows.length, 'Window return replaced stable row identities')
        assert(events == [:resume, :before_focus, :focus], 'Window omitted or duplicated native focus events')
        expected_header = origin == :list ? WINDOWS_HEADER : (action_kind == :add ? 'Add window' : 'Edit window')
        assert_native_presentation(expected_header, origin == :list ? windows.options[expected_index] : nil)
      end
      driver.step(PARTICIPANTS_HEADER, [27])
      assert(editor.wait.nil?, 'Cancelled settings returned local edits')
      driver.finish
      assert(events == [:resume, :before_focus, :focus, :closed] && driver.forms.length == 2 && JSON.generate(row) == before,
        'Window reentry changed the input or revived a closed editor')
      puts "PASS native window #{action_kind} origin=#{origin} close=#{close}: speech/braille, guarded resume/focus and stable selection/text"
    end
  end
end
