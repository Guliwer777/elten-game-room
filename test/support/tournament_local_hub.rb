# encoding: UTF-8
# Pomocniki kompozycji, bez importowania cudzych scenariuszy.
require_relative 'assertions'
require_relative 'tournament_publication_editor'
require_relative '../../games/catalog'
include GameRoomTest::Assertions

module TournamentLocalHubTest
  module_function

  def args(**values)
    {program: Object.new, registry: GameRoomGames::CATALOG, user: -> { 'RealOwner' },
      alert: ->(message) { raise message }, confirm: ->(*) { raise 'Nieoczekiwane potwierdzenie' }}.merge(values)
  end

  def choose(name = 'Testowa Alicja')
    lambda do |form|
      field(form, 'Test participant name').text = name
      button(form, 'Use test participant').trigger(:press)
    end
  end

  def draft
    { 'id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'revision' => 7,
      'name' => 'Szkic — Łódź', 'game_id' => 'chess', 'game_options' => {'bot_delay' => 3},
      'format' => 'round_robin', 'rematch' => false, 'players_per_match' => 2,
      'pairing' => 'all_combinations', 'participants' => ['Lokalna A', 'Lokalna B'],
      'windows' => TournamentPublicationEditorTest.windows }
  end

  def with_drafts(rows, &block)
    workspace = Object.new
    workspace.define_singleton_method(:load) { rows }
    replace(GameRoomTournaments::DraftWorkspace, :new, ->(**_args) { workspace }, &block)
  end

  def button(form, label)
    TournamentPublicationEditorTest.button(form, label)
  end

  def field(form, header)
    TournamentPublicationEditorTest.field(form, header)
  end

  def script(*steps)
    $local_hub_steps = steps
    yield
    assert($local_hub_steps.empty?, 'Pozostały kroki formularza')
  end

  def replace(object, method, callback)
    original = object.method(method)
    object.define_singleton_method(method, callback)
    yield
  ensure
    object.define_singleton_method(method, original)
  end

  module Script
    def focus(*_args)
      field = fields[index]
      field.trigger(:before_focus)
      field.focus(index, fields.length)
      field.trigger(:focus)
    end
    def wait
      super
      ($local_hub_steps.shift || raise('Nieoczekiwany formularz')).call(self)
    end
  end
end
