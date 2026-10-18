# encoding: UTF-8
require_relative '../support/temporary_directory'
require 'tmpdir'
require_relative '../support/binary_rules_load'
require_relative '../../lib/tournaments/draft_workspace'
require_relative '../../lib/tournaments/draft_screen'

def assert(condition, message)
  raise message unless condition
end

assert(defined?(GameRoomTournaments::DraftWorkspace), 'Paczka nie zawiera modułu szkiców')
assert(EltenGameRoom::MAIN_OPTIONS.include?('Turnieje'), 'Paczka nie zawiera polskiego wejścia do turniejów')
registry = EltenGameRoom::GAME_REGISTRY
# Cały nowy interfejs, nie tylko pierwsze trzy formularze pierwszej paczki.
sources = %w[draft_editor draft_screen draft_workspace draft_details_editor window_fields draft_preview].map { |name| "lib/tournaments/#{name}.rb" }
messages = sources.flat_map do |path|
  BinaryRulesLoad.read(File.join(BinaryRulesLoad::ROOT, path)).scan(/_\("([^"\n]*)"\)/).flatten
end
missing = messages.uniq.reject { |message| !RULES_CATALOG[message].to_s.empty? }
assert(missing.empty?, "Brak polskich tłumaczeń: #{missing.join('; ')}")

module PackagedTournamentForm
  def wait
    super
    $packaged_tournament_driver.call(self)
  end
end
Form.prepend(PackagedTournamentForm)

GameRoomTest::TemporaryDirectory.create('tournament-binary-') do |directory|
  program = Object.new
  program.define_singleton_method(:data_path) { directory }
  store = GameRoomTournaments::Drafts.new(program, owner: 'Tester')
  %w[en pl].each do |language|
    GameRoomTestLocalization.use_language(language)
    registry.ids.each do |id|
      game = registry.build(id)
      options = game.default_options
      saved = store.create('name' => game.name, 'game_id' => id, 'game_options' => options)
      assert(store.fetch(saved['id'])['game_options'] == options, "Zapis zmienił domyślne opcje #{id}/#{language}")
    end
    expected = language == 'pl' ? 'Nazwa turnieju' : 'Tournament name'
    $packaged_tournament_driver = lambda do |form|
      assert(form.fields.first.header == expected, "Nieprzetłumaczona nazwa w #{language}")
      form.fields.each do |control|
        values = []
        values << control.header if control.respond_to?(:header) && control.header
        values << control.label if control.respond_to?(:label)
        values.concat(control.options) if control.respond_to?(:options)
        assert(values.all? { |value| value.valid_encoding? && value.encoding == Encoding::UTF_8 }, 'Kontrolka dostała binarne lub uszkodzone etykiety')
      end
      form.fields.first.text = 'Próba — żółty'
      game_list = form.fields.find { |control| control.respond_to?(:options) && control.options.length == registry.ids.length + 1 }
      game_list.index = registry.ids.index('three_five_eight') + 1
      form.accept_button.trigger(:press)
    end
    saved = GameRoomTournaments::DraftEditor.new(program: program, registry: registry,
      configure: ->(*) { nil }, save: ->(attributes) { store.create(attributes) },
      alert: ->(message) { raise message }).wait
    assert(saved['name'] == 'Próba — żółty', 'Paczka zgubiła polskie znaki przy zapisie')
  end
  reopened = GameRoomTournaments::Drafts.new(program, owner: 'tester')
  assert(reopened.list.length == registry.ids.length * 2 + 2, 'Odtworzenie zgubiło szkice gier')
end
puts "PASS binarne źródła: zapis opcji #{registry.ids.length} gier, formularz i polskie znaki w PL/EN"
