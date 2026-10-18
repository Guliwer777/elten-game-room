require_relative '../support/audio_tutorial_native'
load File.join(EltenTestHost.root, 'src/ui/controls/check_box.rb')
Object.send(:remove_const, :CheckBox) if Object.const_defined?(:CheckBox, false)
Object.const_set(:CheckBox, EltenAPI::Controls.const_get(:CheckBox))
FormTimer = EltenAPI::Controls::FormTimer unless defined?(FormTimer)
require_relative '../../lib/game_content'
require_relative '../../lib/game_room_preferences'
require_relative '../../lib/game_room_screens'
require_relative '../support/localization'

def loop_update(*); end
GameRoomTestLocalization.use_language('en')

class BlacklistMenu
  attr_reader :items
  def initialize; @items = []; end
  def option(label, value = nil, key = nil, &action); @items << [label, value, key, action]; end
end

def blacklist_menu(list)
  menu = BlacklistMenu.new
  list.context(menu, false)
  menu
end

class Form
  class << self; attr_accessor :blacklist_driver; end
  def wait; Form.blacklist_driver.call(self); end
end

values = GameRoomPreferences.defaults(['uno']).merge('invitation_blacklist' => [' Alice ', 'alice', 'Bob'])
original = Marshal.dump(values)
games = [{id: 'uno', name: 'UNO'}]
snapshot = {state: :loading, games: []}
Form.blacklist_driver = lambda do |form|
  list = form.fields.find { |field| field.is_a?(GameRoomScreens::InvitationBlacklist) }
  assert(list.is_a?(EltenAPI::Controls::ListBox), 'Blacklist is not a native list')
  assert(form.instance_variable_get(:@hidden)[form.fields.index(list)], 'Blacklist leaked outside Notifications')
  sections = form.fields.first
  sections.index = sections.options.index('Notification settings') or raise 'Notifications category missing'
  sections.trigger(:move)
  assert(!form.instance_variable_get(:@hidden)[form.fields.index(list)], 'Blacklist hidden in Notifications')
  assert(list.header == 'Blacklist' && list.options == %w[Alice Bob], 'Wrong initial list or normalization')
  assert(list.get_tips.any? { |tip| tip.include?('Ctrl+N') } && list.get_tips.any? { |tip| tip.include?('Delete') }, 'Missing keyboard help')
  global = BlacklistMenu.new
  list.context(global, true)
  assert(global.items.empty?, 'Blacklist actions leaked into the global menu')
  menu = blacklist_menu(list)
  assert(menu.items.map { |item| item.first(3) } == [['Add user', nil, 'n'], ['Remove user', nil, :del]], 'Wrong native shortcut bindings')
  answers = [nil, '   ', ' aLiCe ', ' Carol ']
  list.define_singleton_method(:input_text) do |header, escapable:|
    assert(header == 'User name' && escapable, 'Entry dialog cannot be cancelled')
    answers.shift
  end
  2.times { menu.items.first.last.call; assert(list.names == %w[Alice Bob], 'Cancelled/empty name changed list') }
  menu.items.first.last.call
  assert(list.names == %w[Alice Bob] && list.index == 0, 'Duplicate changed spelling or added another row')
  menu.items.first.last.call
  assert(list.names == %w[Alice Bob Carol] && list.index == 2, 'New user not selected')
  copy = list.names
  copy.clear
  assert(list.names == %w[Alice Bob Carol], 'Caller can mutate the staged list')
  list.index = 1
  blacklist_menu(list).items.last.last.call
  assert(list.names == %w[Alice Carol] && list.index == 1, 'Delete removed the wrong selected name')
  snapshot = {state: :ready, games: ['uno']}
  form.instance_variable_get(:@timers).first.instance_variable_get(:@action).call
  assert(list.names == %w[Alice Carol] && form.fields.include?(list), 'Subscription loading replaced staged blacklist')
  assert(Marshal.dump(values) == original, 'Editing mutated the opening settings before Save')
  form.accept_button.trigger(:press)
end
saved = GameRoomScreens::Settings.new(values, games: games, table_watch_available: false,
  table_watch_loader: -> { snapshot }).wait
assert(saved['invitation_blacklist'] == %w[Alice Carol], 'Save lost the staged blacklist')
assert(saved['table_watch_games'] == ['uno'], 'Blacklist interfered with subscription loading')
assert(Marshal.dump(values) == original, 'Save mutated the original object')

Form.blacklist_driver = lambda do |form|
  list = form.fields.find { |field| field.is_a?(GameRoomScreens::InvitationBlacklist) }
  list.index = 1
  2.times { list.remove_user }
  assert(list.names.empty? && list.options.empty? && list.index == 0, 'Removing the last name left a phantom row')
  assert(blacklist_menu(list).items.map(&:first) == ['Add user'], 'Empty list has a Remove action')
  list.remove_user
  form.cancel_button.trigger(:press)
end
assert(GameRoomScreens::Settings.new(saved, games: games, table_watch_available: false).wait.nil?, 'Cancel committed blacklist')
assert(saved['invitation_blacklist'] == %w[Alice Carol], 'Cancelled edits mutated committed values')
puts 'PASS native blacklist list: Notifications, add/remove context shortcuts, cancel/empty/case duplicates, staged Save/Cancel and subscription refresh'
