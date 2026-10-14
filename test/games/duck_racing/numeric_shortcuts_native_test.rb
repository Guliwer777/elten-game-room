require_relative '../../support/duck_challenge_native'
require_relative '../../../lib/game_layout'
require_relative '../../../lib/game_shortcut_bindings'
require_relative '../../../games/duck_racing'

include DuckChallengeTest
module Clipboard
  class << self
    attr_accessor :text
  end
end
module SpeechOutput
  def self.list; []; end
end
driver = DuckChallengeNativeDriver.new
%w[copy_number arithmetic race_question guess_number count_ducks].each do |kind|
  model = challenge_state(kind)
  acknowledge_challenge(model) if kind == 'count_ducks'
  surface = challenge_surface(model)
  form = driver.form(surface)
  form.extend(GameRoomLayout::ShortcutFormBehavior)
  observed = []
  shortcuts = %w[t s c v p].map { |key| GameRoomGames::GameShortcut.new(key: key, label: key, kind: :announcement, message: key) }
  GameRoomShortcutBindings.bind(form, surface.fields, shortcuts, consume: ->(_key) {}) { |shortcut| observed << shortcut.key }
  field = surface.fields.first
  driver.frame(form, driver.tap(0x31), characters: '1')
  draft = field.text.dup
  %w[t s c v p].each do |key|
    before = observed.length
    driver.frame(form, driver.tap(key.upcase.ord), characters: key)
    assert_equal(before + 1, observed.length, "#{kind}: #{key} was swallowed by the numeric edit")
    assert_equal(key, observed.last)
    assert_equal(draft, field.text, 'Game shortcut became part of the numeric answer')
  end
  # Text editing combinations remain native, not the unmodified game key.
  before = observed.dup
  driver.frame(form, driver.tap(0x41, modifiers: [0x11]))
  assert_equal(before, observed)
  [0x43, 0x58, 0x56].each { |key| driver.frame(form, driver.tap(key, modifiers: [0x11])) }
  assert_equal(before, observed, 'Modified text keys triggered a game shortcut')
  # Invoke the native clipboard operations too. The host binds these through
  # its own edit menu / Ctrl+Shift commands, not Game Room's single letters.
  field.index, field.check = 0, field.text.length
  field.copy
  assert_equal(draft, Clipboard.text)
  field.cut
  assert_equal('', field.text)
  field.paste
  assert_equal(draft, field.text)
  driver.frame(form, driver.tap(0x41, modifiers: [0x11]))
  driver.frame(form, driver.tap(0x08))
  assert_equal('', field.text)
  form.index = 1
  form.focus
  before = observed.dup
  driver.frame(form, driver.tap(0x50), characters: 'p')
  assert_equal(before, observed, 'Chat triggered a letter shortcut')
  assert(form.fields.last.text.include?('p'), 'Chat lost ordinary typing')
  surface.deactivate_input
end

%w[copy_number arithmetic race_question].each do |kind|
  view = ENGINE.view(challenge_state(kind), seat: 0)
  assert_equal(GameRoomDuckRacing::ChallengePresentation.prompt(kind, view),
    GameRoomDuckRacing::ChallengePresentation.reminder(kind, view))
end
view = ENGINE.view(challenge_state('guess_number'), seat: 0)
assert(!view.key?(:answer), 'Hidden target leaked in the public view')
assert(GameRoomDuckRacing::ChallengePresentation.reminder('guess_number', view).start_with?('Number from 1 to 999.'), 'Missing guessing reminder')
$activecontrols = []
puts 'PASS numeric fields: T/S/C/V/P, unchanged draft, native editing and chat isolation; task reminder uses the public view'
