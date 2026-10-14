require_relative '../support/game_option_editor_native'
require EltenTestHost.file('src/ui/controls/menu.rb')
require EltenTestHost.file('src/eapi/mainmenu.rb')
Object.const_set(:Menu, EltenAPI::Controls.const_get(:Menu))

def speech_stop(*_arguments); end

NativeOptionTest.language = 'en'
class CreatorKeyDriver
  attr_reader :form, :result

  def initialize(&block)
    @raw, @frame = [], 0
    NativeOptionUI.driver = self
    @fiber = Fiber.new(&block)
    @form = @fiber.resume
    raise 'No waiting native form' unless @fiber.alive? && @form.is_a?(GameRoomUI::Form)
  end

  def tick(owner)
    keys, characters = owner.instance_variable_get(:@wait) ? Fiber.yield(owner) : [[], '']
    state = "\0" * 256
    keys.each { |code| state.setbyte(code, 0x80) }
    events = (@raw - keys).map { |code| [code, false] } + (keys - @raw).map { |code| [code, true] }
    @frame += 1
    EltenAPI::KeyboardState.update(raw_state: state, events: events, now: @frame * 0.1,
      pressed_implies_held: false, synthesize_repeats: false)
    @raw = keys
    NativeOptionUI.characters = characters
    $input_frame_serial = $input_frame_serial.to_i + 1
    $keyboard_state_frame_serial = $input_frame_serial
    $keyboard_state_frame_thread = Thread.current
    # Context-menu shortcuts are dispatched by the host before updating the
    # fields. ListBox deliberately consumes letter events for type-ahead.
    owner.send(:keyprocs)
    $activecontrols = []
  end

  def tap(keys, characters = '')
    outcome = @fiber.resume([keys, characters])
    outcome = @fiber.resume([[], '']) if @fiber.alive?
    @form = outcome if @fiber.alive? && outcome.is_a?(GameRoomUI::Form)
    @result = outcome unless @fiber.alive?
  end

  def waiting?
    @fiber.alive?
  end
end

views = GameRoomQuizContributions::Views.new(EltenGameRoom.allocate)
driver = CreatorKeyDriver.new { views.choose('Choose', ['No', 'Yes'], index: 0) }
driver.tap([39])
NativeOptionTest.assert(driver.form.fields.first.index == 1, 'Right arrow did not change a creator choice')
driver.tap([37])
NativeOptionTest.assert(driver.form.fields.first.index == 0, 'Left arrow did not change a creator choice')
driver.tap([40])
NativeOptionTest.assert(driver.form.fields.first.index == 1, 'Down arrow stopped working')
driver.tap([38])
NativeOptionTest.assert(driver.form.fields.first.index == 0, 'Up arrow stopped working')
driver.tap([27])

empty = GameRoomQuizContributions::Model.new_draft('set')
driver = CreatorKeyDriver.new { views.questions(empty) }
driver.tap([13])
NativeOptionTest.assert(driver.waiting?, 'Enter on empty questions opened a nonexistent item')
driver.tap([17, 78])
NativeOptionTest.assert(!driver.waiting? && driver.result.first == :new, 'Ctrl+N did not add a question from the empty list')

driver = CreatorKeyDriver.new { views.library([]) }
driver.tap([13])
NativeOptionTest.assert(driver.waiting?, 'Enter in an empty library opened a nonexistent set')
driver.tap([17, 78])
NativeOptionTest.assert(!driver.waiting? && driver.result.first == :new, 'Native Ctrl+N did not open creation')
NativeOptionTest.assert(!EltenAPI::KeyboardState.current.held.any?, 'Ctrl+N leaked into the next dialog')

draft = GameRoomQuizContributions::Model.new_draft('set')
draft['title'] = 'Keyboard test'
driver = CreatorKeyDriver.new { views.library([draft]) }
driver.tap([78], 'n')
NativeOptionTest.assert(driver.waiting?, 'Unmodified N opened creation')
driver.tap([17, 16, 78])
NativeOptionTest.assert(driver.waiting?, 'Ctrl+Shift+N opened creation')
driver.tap([17, 82])
NativeOptionTest.assert(!driver.waiting? && driver.result.first == :refresh, 'Native Ctrl+R did not refresh')

driver = CreatorKeyDriver.new { views.set_menu(draft) }
driver.tap([40])
NativeOptionTest.assert(driver.form.fields.first.options[driver.form.fields.first.index] == 'Browse questions', 'Arrow did not select Browse questions')
driver.tap([13])
NativeOptionTest.assert(!driver.waiting? && driver.result == [:open, 1], 'Native Enter did not select Browse questions')

draft['categories'] = %w[One Two]
driver = CreatorKeyDriver.new { views.edit_question(draft, index: 0) { views.new_category } }
driver.tap([65], 'a')
driver.tap([13])
NativeOptionTest.assert(driver.waiting?, 'Enter in question submitted instead of editing')
6.times { driver.tap([9]) }
NativeOptionTest.assert(driver.form.fields[driver.form.index].header == 'Category', 'Tab did not reach category')
driver.tap([40])
NativeOptionTest.assert(driver.form.fields[6].index == 1, 'Native arrow did not change category')
outer_form = driver.form
driver.tap([35])
NativeOptionTest.assert(driver.form.fields[6].options.last == 'Add a new category', 'Last category item is not the creation action')
driver.tap([13])
NativeOptionTest.assert(driver.form.fields.first.header == 'Category name', 'Enter did not open inline category editor')
'Three'.each_char { |character| driver.tap([character.upcase.ord], character) }
driver.tap([9])
driver.tap([13])
NativeOptionTest.assert(driver.form.equal?(outer_form), 'Inline category replaced question form')
NativeOptionTest.assert(driver.form.fields[6].options[driver.form.fields[6].index] == 'Three', 'Native category creation did not select it')
NativeOptionTest.assert(driver.form.fields[0].text.include?('a'), 'Native category creation lost typed question')
driver.tap([35])
driver.tap([13])
driver.tap([27])
NativeOptionTest.assert(driver.form.equal?(outer_form) && driver.form.fields[6].options[driver.form.fields[6].index] == 'Three', 'Cancelling inline category lost focus or selection')
3.times { driver.tap([9]) }
NativeOptionTest.assert(driver.form.fields[driver.form.index].label == 'Save', 'Tab did not reach Save')
driver.tap([13])
NativeOptionTest.assert(!driver.waiting? && driver.result.first == :save, 'Native Enter did not save question')
NativeOptionTest.assert(driver.result.last['category'] == 'Three', 'Category selection was lost')

driver = CreatorKeyDriver.new { views.notice("Question 1: Enter answer C.\r\nQuestion 2: Enter the question.") }
NativeOptionTest.assert(driver.waiting?, 'Missing fields dialog did not wait')
driver.tap([27])
NativeOptionTest.assert(!driver.waiting?, 'Escape did not close missing fields dialog')
puts "PASS creator native keyboard: #{NativeOptionTest.checks} checks"
