module GameRoomTest
  # Shared catalogue fixtures must select a legal profile, not assume that a
  # game's default variant has two seats or bots. Keep explicit declared values.
  module CatalogOptions
    module_function

    def for_players(game, minimum: 2, bots: false)
      candidates = [game.default_options]
      game.effective_option_definitions.each do |definition|
        next unless definition.kind.to_s == 'choice' && game.option_visible?(definition, {})
        definition.choices.each do |choice|
          candidates << game.normalize_options(definition.key.to_s => choice.value)
        end
      end
      candidates.uniq.find do |options|
        (!bots || game.supports_bots_for_options?(options)) &&
          (minimum..game.maximum_players).any? { |size| !game.validation_error(options, player_count: size) }
      end || raise("No legal test profile for #{game.id}, at least #{minimum} players, bots=#{bots}")
    end
  end
end
