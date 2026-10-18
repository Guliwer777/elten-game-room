# encoding: UTF-8
require_relative 'game_result'
require_relative 'strict_json'
require_relative '../tournament_presence'
require 'digest'

module GameRoomTournaments
  # Automatic export of one explicitly bound ordinary game's verified history.
  class OrdinaryMatchResults
    def self.read(repository:, registry:, transport:, table:, binding:)
      binding = Publication::Data.copy(binding)
      raise Publication::Invalid, :tournament_saved_game_disabled if binding.key?('continuation')
      unless table['__id'] == binding['table']['__id'] && table['__live_session_id'] == binding['table']['__live_session_id']
        raise Publication::Invalid, :wrong_game_table
      end
      session = repository.session_by_id(binding.fetch('session_id'), table: table)
      return nil unless session
      snapshot = session && repository.snapshot_for(session, force_events: true)
      raise Publication::Invalid, :missing_bound_session unless snapshot
      session = snapshot.session
      unless session['table_id'] == table['__id'] && session['game'] == binding['game_id'] &&
          ((!session['__aborted'] && !session['__frozen']) || GameRoomTournamentPresence.ended?(session)) &&
          !session['__restored'] && !session['__archive_id']
        raise Publication::Invalid, :wrong_bound_session
      end
      game = registry.build(binding['game_id'])
      replay = game.replay(session, snapshot.events, repository)
      return nil unless replay.finished? || GameRoomTournamentPresence.ended?(session)
      capture(registry:registry,binding:binding,session:session,replay:replay,events:snapshot.events)
    end

    def self.capture(registry:, binding:, session:, replay:, events:)
      if binding.key?('continuation') || session['__restored'] || session['__archive_id']
        raise Publication::Invalid, :tournament_saved_game_disabled
      end
      unless session['__id']==binding['session_id'] && session['table_id']==binding['table']['__id'] && session['game']==binding['game_id'] &&
          ((!session['__aborted'] && !session['__frozen']) || GameRoomTournamentPresence.ended?(session)) && valid_continuation?(binding,session,events)
        raise Publication::Invalid,:wrong_bound_session
      end
      game=registry.build(binding['game_id'])
      options=game.normalize_options(StrictJson.parse(session.fetch('options'),max_nesting:12))
      expected=game.normalize_options(binding.fetch('options'))
      normalize_roster=->(value) do
        if value.key?('team_players') && !value['team_players'].is_a?(Array)
          raise Publication::Invalid,:wrong_game_options
        end
        value.key?('team_players') ? value.merge('team_players'=>value['team_players'].map{|name|Publication::Data.account(name).downcase}) : value
      end
      raise Publication::Invalid,:wrong_game_options unless normalize_roster.call(options)==normalize_roster.call(expected)
      players=binding.fetch('players')
      groups = GameResult.eliminations(replay, players: players)
      projected_groups = session.dig('__tournament_presence', 'eliminations').to_a.map { |group| group.map(&:downcase).sort }
      raise Publication::Invalid, :wrong_bound_session unless groups == projected_groups
      return capture_absence(binding, session, replay, events, game: game, options: options, groups: groups) if GameRoomTournamentPresence.ended?(session)
      summary = GameResult.from_replay(game: game, replay: replay, players: players, options: options,
        event_count: events.size, events: events, result_policy: GameResult::CURRENT_RESULT_POLICY)
      summary = GameResult.with_eliminations(summary, groups)
      Publication::Data.freeze_tree({'kind' => 'ordinary-match-result-v1', 'binding_digest' => Digest::SHA256.hexdigest(JSON.generate(binding)),
        'match_id' => binding['match_id'], 'leg' => binding['leg'], 'session_id' => binding['session_id'],
        'history_digest' => Digest::SHA256.hexdigest(JSON.generate(events)), 'summary' => summary})
    end

    def self.capture_absence(binding, session, replay, events, game:, options:, groups:)
      presence = session.fetch('__tournament_presence')
      players = binding.fetch('players')
      accounts = players.map { |person| person.fetch('account') }.sort
      loser = presence['loser'].downcase
      unless accounts.size >= 2 && players.none? { |person| person.key?('team') } &&
          accounts.include?(loser) && presence['absent'].map(&:downcase) == [loser] &&
          presence['totals_ms'].fetch(presence['loser']) == GameRoomTournamentPresence::LIMIT_MS &&
          presence['binding_digest'] == Digest::SHA256.hexdigest(JSON.generate(binding)) &&
          presence['fixture'] == binding['table']['tournament_match'] &&
          GameResult.valid_replay_history?(replay, events) && !replay.finished? &&
          replay.players.map { |person| Publication::Data.account(person).downcase }.sort == accounts
        raise Publication::Invalid, :wrong_bound_session
      end
      checkpoint = GameResult.checkpoint(game: game, replay: replay, options: options, players: players)
      continuation = game.tournament_forfeit_continuation(replay, losing_unit: presence['loser'], options: options)
      outcome = InterruptedOutcome.build(units: accounts, loser: loser, started: true,
        checkpoint: checkpoint, continuation: continuation, event_count: events.size, eliminations: groups)
      raise Publication::Invalid, :wrong_bound_session unless outcome.dig('decision', 'mode') == 'terminal'
      summary = outcome.fetch('summary')
      # Preserve the already published two-seat automatic result shape.
      summary = summary.reject { |key, _| %w[places score_order].include?(key) }.merge('scores'=>nil) if accounts.size == 2
      Publication::Data.freeze_tree({'kind'=>'ordinary-match-result-v1', 'binding_digest'=>presence['binding_digest'],
        'match_id'=>binding['match_id'], 'leg'=>binding['leg'], 'session_id'=>binding['session_id'],
        'history_digest'=>Digest::SHA256.hexdigest(JSON.generate([events, presence])), 'summary'=>summary,
        'absence'=>{'loser'=>loser, 'boundary_id'=>presence['boundary_id'], 'elapsed_ms'=>GameRoomTournamentPresence::LIMIT_MS}})
    end
    def self.valid_continuation?(binding,session,events)
      marker=binding['continuation']
      return !session['__archive_id'] unless marker
      marker.is_a?(Hash) && marker['archive_id']==session['__archive_id'] &&
        marker['event_count'].is_a?(Integer) && marker['event_count']>=0 && events.size>=marker['event_count'] &&
        marker['prefix_digest']==Digest::SHA256.hexdigest(JSON.generate(events.first(marker['event_count']).map{|event|event.slice('actor','action','value')}))
    end
  end
end
