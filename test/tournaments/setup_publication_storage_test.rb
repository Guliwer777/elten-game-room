require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
require_relative '../../lib/tournaments/local_workspace'
require_relative '../../lib/tournaments/local_test_hub'
require 'tmpdir'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
Form.prepend(TournamentPublicUI::Script)
def loop_update; Thread.pass; end
T = TournamentPublicUI
G = GameRoomTournaments
G::DraftWorkspace.prepend(Module.new do
  def configure(_game,options); options; end
end)
Dir.mktmpdir('setup-storage-', ENV.fetch('TMPDIR')) do |base|
  # Match the installed program's data path length; journal names then exceed MAX_PATH.
  root = File.join(base, 'installed-program-data-' + 'x' * 35)
  FileUtils.mkdir_p(root)
  program = Object.new
  program.define_singleton_method(:data_path) { root }
  program.define_singleton_method(:server_tables) { raise 'Unexpected network access' }
  messages = []
  clock = -> { Time.local(2026,10,11,15,0).to_i }
  make = -> { G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { 'guliwer' }, actor: 'guliwer', alert: ->(m) { messages << m }, clock: clock) }
  workspace = make.call
  T.script(lambda do |form|
    game=T.field(form,'Game');game.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe');game.trigger(:select)
  end,lambda do |form|
    T.field(form, 'Tournament name').text = 'Stored unified tournament'
    T.field(form, 'Tournament format').index = 1
    T.field(form, 'Return matches in knockout rounds').index = 1
    T.field(form, 'Return match in the final').index = 0
    form.accept_button.trigger(:press)
  end) do
    G::TournamentSetupEditor.new(program: program, registry: GameRoomGames::CATALOG,
      configure: ->(_game,options) { options }, clock: clock, alert: ->(m) { messages << m },
      publish: ->(**values) { workspace.publish(intent_id: 'setup-storage-test', **values) }).wait
  end
  raise "Publication failed: #{workspace.last_error.inspect}; #{messages.inspect}" if workspace.last_error || !messages.empty?
  snapshot = make.call.load
  raise 'Publication did not survive reopening' unless snapshot.inspect.include?('Stored unified tournament')
  raise 'Creator was not enrolled automatically' unless snapshot['members'].any? { |person| person['account'] == 'guliwer' }
  settings = JSON.parse(snapshot['announcements'].first['settings_json'])
  stored = snapshot['announcements'].first
  raise 'New setup did not store UTC' unless stored['timezone'] == 'UTC'
  window = JSON.parse(stored['schedule_json'])['windows'].first
  actual_start = G::LocalRegistrationTime.convert_utc(window['date'], window['start'])
  raise 'Setup changed the selected instant' unless actual_start == clock.call + 3600
  T.script(lambda do |form|
    form.cancel_button.trigger(:press)
  end) do
    reopened = G::TournamentSetupEditor.new(program: program, registry: GameRoomGames::CATALOG,
      configure: ->(*) { nil }, clock: clock, alert: ->(m) { raise m },
      publication: stored, publish: ->(**) { raise 'Cancelled edit wrote publication' })
    reopened.wait
    fields = reopened.instance_variable_get(:@playing_start)
    raise 'UTC edit reopened at another local date' unless fields.date == Time.at(actual_start).getlocal.strftime('%Y-%m-%d')
    raise 'UTC edit reopened at another local hour' unless fields.time == Time.at(actual_start).getlocal.strftime('%H:%M')
  end
  raise 'Groups lost compact qualification' unless settings['group_advancement'] == G::GroupAdvancement::COMPACT
  raise 'Independent round settings lost' unless settings['knockout_rematch'] == true && settings['final_rematch'] == false
  T.script(lambda do |form|
    raise 'Unexpected participant prompt' unless form.fields.first.header == 'Game'
    form.cancel_button.trigger(:press)
  end,lambda do |form|
    form.cancel_button.trigger(:press)
  end) do
    G::LocalTestHub.new(program: program, registry: GameRoomGames::CATALOG,
      user: -> { 'guliwer' }, alert: ->(m) { raise m }, confirm: ->(*) { raise 'Unexpected confirmation' },
      clock: clock, open_setup: true).run
  end
  T.script(lambda do |form|
    game=T.field(form,'Game');game.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe');game.trigger(:select)
  end,lambda do |form|
    T.field(form, 'Tournament name').text = 'Signed-in organizer'
    form.accept_button.trigger(:press)
  end, lambda do |form|
    raise 'Organizer not displayed' unless form.fields.first.text.include?('guliwer')
    form.cancel_button.trigger(:press)
  end) do
    G::LocalTestHub.new(program: program, registry: GameRoomGames::CATALOG,
      user: -> { 'guliwer' }, alert: ->(m) { raise m }, confirm: ->(*) { raise 'Unexpected confirmation' },
      clock: clock, open_setup: true).run
  end
  row = make.call.load['announcements'].find { |item| item['title'] == 'Signed-in organizer' }
  raise 'Publication author differs from signed-in organizer' unless row && row['__insertion_user'] == 'guliwer'
end
puts 'PASS unified setup publishes and reopens using long Windows storage paths'
