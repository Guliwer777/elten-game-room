# encoding: UTF-8
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/publication'

module TournamentMatchFixture
  module_function

  def registry
    GameRoomGames::CATALOG
  end

  def payload(game_id: 'uno', names: %w[Alice Bob])
    game = registry.build(game_id)
    { 'contract_version' => 1,
      'scope' => { 'namespace' => 'tournament', 'backend_identity' => 'fixture:owner',
        'app_uuid' => 'test-app', 'tournament_id' => 'tournament-1' },
      'seal_id' => 'seal-1', 'seal_revision' => 'seal-r1', 'plan_id' => 'plan-1',
      'plan_revision' => 'plan-r1', 'match_id' => 'match-1', 'leg' => 1,
      'execution_generation' => 'execution-1', 'roles_status' => 'confirmed',
      'role_policy_ref' => 'explicit-fixture-policy',
      'players' => names.each_with_index.map { |name, index| { 'account' => name.downcase,
        'username' => name, 'role' => 'player', 'seat' => index, 'team' => nil,
        'game_role' => 'approved-by-fixture' } },
      'observers' => [], 'game_id' => game_id, 'options' => game.normalize_options(game.default_options),
      'reservation' => { 'id' => 'reservation-1', 'revision' => 'reservation-r1', 'fencing' => 7,
        'ready_versions' => names.to_h { |name| [name.downcase, 'ready-r1'] } },
      'create' => { 'operation_id' => 'create-1', 'proof_ref' => 'proof-1' },
      'native_uuid' => '11111111-2222-3333-4444-555555555555', 'table_id' => 42 }
  end

  def invalid
    begin
      yield
    rescue GameRoomTournaments::Publication::Invalid
      return true
    end
    false
  end
end
