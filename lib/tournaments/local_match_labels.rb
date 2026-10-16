# encoding: UTF-8
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomTournaments
  module LocalMatchLabels
    using GameRoomLocalization::Translations
    module_function

    def phase(record)
      candidate = record.fetch('preview').fetch('source').fetch('candidate')
      knockout = candidate['knockout']
      label = if knockout && knockout['qualification']
        _("Additional qualification games, attempt %{number}") % {number: knockout['qualification']['attempt']}
      elsif knockout && knockout['replay']
        _("Additional knockout games, attempt %{number}. Only unresolved matches are repeated.") % {number: knockout['replay']['attempt']}
      elsif knockout
        knockout['seeds'].size == knockout['players_per_match'] ? _("Final") :
          _("Knockout round %{number}") % {number: knockout['round']}
      elsif candidate['format'] == 'groups_knockout'
        _("Group stage")
      else
        _("Round robin")
      end
      GameRoomContent.utf8(label)
    end

    def number(record, match)
      fixtures = record.fetch('evidence').fetch('plan').fetch('matches')
      index = fixtures.index { |row| row['match_id'] == match['match_id'] && row['leg'] == match['leg'] }
      # Presentation never substitutes for the accepted selection identity.
      raise ArgumentError, 'Match outside accepted plan' unless index
      index + 1
    end

    def match(record, match)
      label = match['leg'] == 2 ? _("Match %{number}, return match: %{players}") : _("Match %{number}: %{players}")
      GameRoomContent.utf8(label) % {number: number(record, match),
        players: match.fetch('players').map { |player| player.fetch('username') }.join(' — ')}
    end
  end
end
