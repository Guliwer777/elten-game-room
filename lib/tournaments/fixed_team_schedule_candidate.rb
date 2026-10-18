# encoding: UTF-8
require 'digest'
require_relative 'schedule_source'
require_relative 'league_plan'
require_relative 'fixed_team_seats'
require_relative 'group_schedule'
require_relative 'knockout_schedule'

module GameRoomTournaments
  # Jednostki planujemy przed rozwinięciem kont; nie filtrujemy meczów osób.
  class FixedTeamScheduleCandidate
    Data = Publication::Data
    Invalid = Publication::Invalid

    def self.copy(value)
      Data.copy(value, max_bytes: 262_144, max_nodes: 16_384, max_depth: 12)
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(copy(value)))
    end

    def self.build(projection:, publication_ref:, backend_identity:, observed_at:, membership:, team_template:)
      input = copy({'membership' => membership, 'team_template' => team_template})
      observed = ScheduleSource.build(projection: projection, publication_ref: publication_ref,
        backend_identity: backend_identity, observed_at: observed_at)
      row, settings, schedule, members, reference, backend = observed.values_at(:row, :settings, :schedule, :members, :publication_ref, :backend_identity)
      roster = members.map { |person| person.slice('account', 'username') }
      membership = FixedTeamSeats.membership(input['membership'], roster)
      pair_events = projection.pairing_used?(row['__id'])
      if FixedTeamSeats.unit_size(membership) == 2 && pair_events
        expected = projection.to_h['pairs'].select { |pair| pair['tournament_id'] == row['__id'] }.map { |pair| pair['accounts'].sort }.sort
        raise Invalid, :source_changed unless membership['units'].map { |unit| unit['accounts'].sort }.sort == expected
      end
      template = FixedTeamSeats.template(input['team_template'], options: settings['game_options'], unit_size: FixedTeamSeats.unit_size(membership))
      budget!(membership, roster, schedule['windows'], settings['rematch']) unless settings['format'] == 'groups_knockout'
      content = Publication::COLUMNS.to_h { |key| [key, row.fetch(key)] }
      content_digest = digest(content)
      generation = digest(['tournament-fixed-team-roster-v1', backend, reference, content_digest, roster, membership])
      units = membership['units'].to_h { |unit| [unit['unit_id'], unit['accounts']] }
      groups = nil
      direct = settings['format'] == 'groups_knockout' && ['automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(settings['group_advancement']) && units.size == 2
      if direct
        matches = LeaguePlan.build(participants: units.keys, players_per_match: 2, pairing: settings['pairing'], rematch: false)
      elsif settings['format'] == 'groups_knockout'
        matches, groups = GroupSchedule.build(roster: units.keys, settings: settings, players_per_match: 2)
        unless roster.size <= 256 && schedule['windows'].size.between?(0, 256)
          raise Invalid, :execution_plan_limit
        end
      else
        matches = LeaguePlan.build(participants: units.keys, players_per_match: 2,
          pairing: settings['pairing'], rematch: settings['rematch'])
      end
      schedule_id = digest(['tournament-fixed-team-schedule-v1', generation, settings['pairing'], settings['rematch'], template,
        matches.map { |match| match.values_at('players', 'leg') }])
      matches = matches.map do |match|
        ids = match['players']
        {'number' => match['number'], 'unit_ids' => ids, 'players' => ids.flat_map { |id| units.fetch(id) }, 'leg' => match['leg'],
          'match_id' => digest(['tournament-fixed-team-match-v1', schedule_id, ids, match['leg']])}
      end
      data = {'source_kind' => 'fixed-teams', 'source_version' => membership['version'], 'membership' => membership,
        'team_template' => template, 'roster_digest' => generation, 'roster_generation' => generation,
        'schedule_id' => schedule_id, 'backend_identity' => backend, 'publication_ref' => reference,
        'publication_digest' => content_digest, 'format' => settings['format'], 'pairing' => settings['pairing'],
        'rematch' => settings['rematch'], 'players_per_match' => settings['players_per_match'], 'roles_teams' => 'unassigned',
        'timezone' => row['timezone'], 'registration_opens_at' => row['registration_opens_at'],
        'registration_closes_at' => row['registration_closes_at'], 'observed_at' => observed_at,
        'state' => 'observed_candidate', 'finality' => 'unknown', 'dispatch_allowed' => false,
        'finalize_allowed' => false, 'start_allowed' => false, 'roster' => roster.map { |person| person['account'] },
        'matches' => matches, 'game_id' => row['game'], 'game_options' => settings['game_options'], 'windows' => schedule['windows']}
      data['groups'] = GroupSchedule.metadata(groups, matches) if groups
      data['starts_at']=schedule['starts_at'] if TournamentTiming.optional?(row)
      data['daily_hours']=schedule['daily_hours'] if schedule['daily_hours']
      data['group_advancement'] = settings['group_advancement'] if settings.key?('group_advancement')
      Publication::ROUND_SETTINGS.each { |key| data[key] = settings[key] } if settings.key?('knockout_rematch')
      Publication::WIN_SETTINGS.each{|key|data[key]=settings[key] if settings.key?(key)}
      if direct
        data.merge!('format' => 'knockout', 'rematch' => settings['final_rematch'] == true,
          'knockout' => KnockoutSchedule.direct_metadata(seeds: units.keys, generation: generation, publication_digest: content_digest, rematch: settings['final_rematch'] == true,target:settings['final_wins_to']))
        data['schedule_id'], data['matches'] = KnockoutSchedule.matches(metadata: data['knockout'], generation: generation, membership: membership)
      end
      new(copy(data))
    end

    def self.budget!(membership, roster, windows, rematch)
      count = membership['units'].size
      matches = count * (count - 1) / 2 * (rematch ? 2 : 1)
      unless roster.size <= 256 && windows.size.between?(0, 256) && matches.between?(1, 256)
        raise Invalid, :execution_plan_limit
      end
    end

    def initialize(data)
      @data = Data.freeze_tree(data)
      freeze
    end
    private_class_method :new

    def to_h
      @data
    end
  end
end
