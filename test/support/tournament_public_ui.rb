# encoding: UTF-8
# Dane wyłącznie pamięciowe. To nie jest serwer ani test transportu.
require_relative 'assertions'
include GameRoomTest::Assertions
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/registration_projection'

module TournamentPublicUI
  MODE = 'Local test — this computer only'.freeze
  ACTOR = 'Żaneta'.freeze
  module_function

  def publication(id = 11, game: 'chess', options: {}, **changes)
    model = GameRoomGames::CATALOG.build(game)
    draft = { 'name' => "Próba #{id} — Łódź", 'game_id' => game, 'game_options' => options,
      'format' => 'round_robin', 'rematch' => false, 'players_per_match' => model.minimum_players,
      'pairing' => 'all_combinations', 'participants' => ['NIE POKAZUJ ROSTERU'],
      'windows' => [{ 'date' => '2026-10-15', 'start' => '18:00', 'end_date' => '2026-10-15', 'end' => '21:00' }] }
    draft.merge!(changes)
    GameRoomTournaments::Publication.from_draft(draft: draft, registry: GameRoomGames::CATALOG,
      publication_key: "publication-#{id}", rules: 'Regulamin: graj uczciwie. Żółć.',
      registration_opens_at: 100, registration_closes_at: 200, timezone: 'UTC').to_row.merge(
        '__id' => id, '__insertion_user' => 'Organizator Łukasz', '__insertion_time' => 90)
  end

  def registration(id, tournament_id: 11, user: ACTOR, key: "join-#{id}", time: 150)
    { '__id' => id, '__insertion_user' => user, '__insertion_time' => time,
      'tournament_id' => tournament_id, 'kind' => 'join', 'operation_key' => key }
  end

  def snapshot(rows = [publication], registrations = [])
    result = GameRoomTournaments::RegistrationProjection.build(announcements: rows, registrations: registrations,
      registry: GameRoomGames::CATALOG, complete: true).to_h
    # ServerWorkspace adds verified sporting completion after registration
    # projection. A date boundary alone is not a completed competition.
    result.merge('announcements'=>result.fetch('announcements').map do |row|
      original=rows.find { |source| source['__id']==row['__id'] }
      row.merge(original.slice('sporting_completed','sporting_completed_at'))
    end)
  end

  # Atrapa wyniku callbacku dziennika, bez dysku i bez wymyślonego serwera.
  def record(status, tournament_id: 11)
    GameRoomTournaments::Publication::Data.freeze_tree({
      'id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'revision' => status == 'prepared' ? 1 : 2,
      'status' => status, 'kind' => 'join', 'intent_id' => "join:#{tournament_id}",
      'table_name' => 'tournament_registrations',
      'values' => { 'tournament_id' => tournament_id, 'operation_key' => 'ui-test-operation', 'kind' => 'join' },
      'evidence' => %w[prepared attempted].include?(status) ? nil : { 'status' => status }
    })
  end

  def button(form, label)
    form.fields.find { |field| field.is_a?(Button) && field.label == label } || raise("Brak przycisku #{label}")
  end

  def field(form, header)
    form.fields.find { |field| field.respond_to?(:header) && field.header == header } || raise("Brak pola #{header}")
  end

  def arguments(snapshot, **options)
    { program: Object.new, registry: GameRoomGames::CATALOG, snapshot: snapshot,
      publication: snapshot.fetch('announcements').first, load: -> { snapshot },
      join: ->(*) { raise 'Nieoczekiwany zapis' }, alert: ->(message) { raise message },
      mode_label: MODE, actor: ACTOR }.merge(options)
  end

  # Uzupełnia wyłącznie lekką atrapę, zgodnie z Form#focus hosta.
  module Script
    def focus(*_arguments)
      control = fields[index]
      return unless control
      control.trigger(:before_focus)
      control.focus(index, fields.length)
      control.trigger(:focus)
    end

    def wait
      super
      action = $public_ui_steps.shift || raise('Nieoczekiwany formularz')
      action.call(self)
    end
  end

  def script(*steps)
    $public_ui_steps = steps
    yield
    assert($public_ui_steps.empty?, 'Niewykonane kroki formularza')
  end
end
