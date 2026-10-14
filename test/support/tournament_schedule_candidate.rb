# encoding: UTF-8
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/registration_projection'
require_relative '../../lib/tournaments/league_plan'

module TournamentScheduleCandidateFixture
  T = GameRoomTournaments
  module_function

  def draft(game_id: 'three_five_eight', players: 3, **changes)
    { 'name' => 'Testowy turniej', 'game_id' => game_id,
      'game_options' => GameRoomGames::CATALOG.build(game_id).default_options,
      'format' => 'round_robin', 'rematch' => true, 'players_per_match' => players,
      'pairing' => 'balanced_cycle', 'participants' => ['NOT-A-REGISTRANT'],
      'windows' => [{ 'date' => '2026-10-15', 'start' => '12:00',
        'end_date' => '2026-10-15', 'end' => '21:00' }] }.merge(changes.transform_keys(&:to_s))
  end

  def announcement(draft: self.draft, id: 30, author: 'Test Organizer', key: 'fixture-schedule',
    registry: GameRoomGames::CATALOG, **changes)
    T::Publication.from_draft(draft: draft, registry: registry,
      publication_key: key, rules: 'Test only.', registration_opens_at: 100,
      registration_closes_at: 200, timezone: 'Europe/Warsaw', **changes).to_row.merge(
        '__id' => id, '__insertion_user' => author, '__insertion_time' => 90)
  end

  def join(id, account, tournament: 30, time: 150, key: "join-#{id}")
    T::RegistrationProjection.join_values(tournament_id: tournament, operation_key: key).merge(
      '__id' => id, '__insertion_user' => account, '__insertion_time' => time)
  end

  def joins(names = %w[Charlie Alice Bob Dana])
    names.each_with_index.map { |name, i| join(i + 1, name) }
  end

  def projection(announcements: [announcement], registrations: joins, complete: true, registry: GameRoomGames::CATALOG)
    T::RegistrationProjection.build(announcements: announcements, registrations: registrations,
      registry: registry, complete: complete)
  end

  # Wyłącznie kontrakt otwartych danych (Float, głębokość), nie zastępstwo 32 gier.
  def data_registry(options)
    game = Object.new
    game.define_singleton_method(:default_options) { options }
    game.define_singleton_method(:effective_option_definitions) { |_selected = {}| [] }
    game.define_singleton_method(:normalize_options) { |selected| selected }
    game.define_singleton_method(:minimum_players) { 2 }
    game.define_singleton_method(:maximum_players) { 2 }
    game.define_singleton_method(:validation_error) { |_selected, player_count:| nil }
    registry = Object.new
    registry.define_singleton_method(:build) { |_id| game }
    registry
  end

  def with_planner(replacement)
    original = T::LeaguePlan.method(:build)
    T::LeaguePlan.define_singleton_method(:build, replacement)
    yield
  ensure
    T::LeaguePlan.define_singleton_method(:build, original)
  end

  def nested(depth, leaf = 'liść')
    depth.times.reduce(leaf) { |value, _| [value] }
  end

  def reference
    { 'author' => 'test organizer', 'publication_key' => 'fixture-schedule' }
  end

  def json_nodes(value)
    case value
    when Hash then 1 + value.sum { |key, child| json_nodes(key) + json_nodes(child) }
    when Array then 1 + value.sum { |child| json_nodes(child) }
    else 1
    end
  end

  def tree_values(value)
    children = case value
    when Hash then value.values
    when Array then value
    else []
    end
    [value, *children.flat_map { |child| tree_values(child) }]
  end

  def build(projection: self.projection, **changes)
    T::ScheduleCandidate.build(projection: projection, publication_ref: reference,
      backend_identity: 'local_test:fixture-A', observed_at: 200, **changes)
  end
end
