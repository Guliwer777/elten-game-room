# encoding: UTF-8
require_relative 'publication'
require_relative '../game_participants'

module GameRoomTournaments
  # Ścisła granica przed liberalnym to_i, deduplikacją i automatycznym fallbackiem.
  module FixedTeamSeats
    Data = Publication::Data
    Invalid = Publication::Invalid
    POLICY = 'fixed-team-two-sides-v1'.freeze
    LARGE_POLICY = 'fixed-team-two-sides-v2'.freeze
    module_function

    def fields?(value, keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def membership(value, roster)
      size = unit_size(value)
      fields = value['version'].eql?(1) ? %w[version kind units] : %w[version kind team_size units]
      unless fields?(value, fields) && value['kind'] == 'fixed-teams' &&
          value['units'].is_a?(Array) && value['units'].size.between?(2, 128)
        raise Invalid, :invalid_membership
      end
      accounts = roster.map { |person| person.fetch('account') }
      units = value['units'].map do |unit|
        unless fields?(unit, %w[unit_id accounts]) && Data.text?(unit['unit_id']) &&
            unit['unit_id'].match?(/\A[A-Za-z0-9_-]{1,64}\z/) && unit['accounts'].is_a?(Array) &&
            unit['accounts'].size == size && unit['accounts'].all? { |account| accounts.include?(account) && !GameRoomParticipants.bot?(account) }
          raise Invalid, :invalid_membership
        end
        {'unit_id' => unit['unit_id'].dup, 'accounts' => unit['accounts'].sort.map(&:dup)}
      end.sort_by { |unit| unit['unit_id'] }
      ids = units.map { |unit| unit['unit_id'].downcase }
      members = units.flat_map { |unit| unit['accounts'] }
      unless ids.uniq.size == ids.size && members.uniq.size == members.size && members.sort == accounts.sort
        raise Invalid, :invalid_membership
      end
      result = {'version' => value['version'], 'kind' => 'fixed-teams', 'units' => units}
      result['team_size'] = size if value['version'].eql?(2)
      result
    end

    def unit_size(value)
      return 2 if value.is_a?(Hash) && value['version'].eql?(1)
      if value.is_a?(Hash) && value['version'].eql?(2) && value['team_size'].is_a?(Integer) && value['team_size'].between?(3, 128)
        return value['team_size']
      end
      raise Invalid, :invalid_membership
    end

    def policy(value)
      unit_size(value) == 2 ? POLICY : LARGE_POLICY
    end

    def assign(candidate, base, roster)
      members = membership(candidate['membership'], roster)
      template = template(candidate['team_template'], options: candidate['game_options'], unit_size: unit_size(members))
      units = members['units']
      first = candidate['matches'].select { |match| match['leg'] == 1 }
      unless base.is_a?(Hash) && base.keys.sort == first.map { |match| match['match_id'] }.sort
        raise Invalid, :invalid_base_seats
      end
      first.each { |match| groups(base[match['match_id']], match['unit_ids'], units, template) }
      people = roster.to_h { |person| [person['account'], person.slice('account', 'username')] }
      teams = units.flat_map { |unit| unit['accounts'].map { |account| [account, unit['unit_id']] } }.to_h
      candidate['matches'].map do |match|
        origin = first.find { |item| item['unit_ids'] == match['unit_ids'] }
        raise Invalid, :niezgodny_mecz unless origin && [1, 2].include?(match['leg'])
        sides = groups(base.fetch(origin['match_id']), match['unit_ids'], units, template)
        sides = sides.reverse if match['leg'] == 2
        accounts = template.each_with_index.map { |side, seat| sides[side][template.take(seat).count(side)] }
        {'match_id' => match['match_id'], 'leg' => match['leg'], 'observers' => [],
          'players' => accounts.each_with_index.map do |account, seat|
            people.fetch(account).merge('role' => 'player', 'seat' => seat, 'team' => teams.fetch(account), 'game_role' => "seat:#{seat}")
          end}
      end
    end

    def groups(accounts, ids, units, template)
      unless accounts.is_a?(Array) && accounts.size == template.size && accounts.all? { |account| Data.text?(account) } &&
          accounts.uniq.size == template.size && ids.is_a?(Array) && ids.size == 2 && ids.uniq.size == 2
        raise Invalid, :invalid_base_seats
      end
      expected = ids.map { |id| units.find { |unit| unit['unit_id'] == id } }
      raise Invalid, :invalid_base_seats if expected.any?(&:nil?)
      sides = [0, 1].map { |side| accounts.each_with_index.filter_map { |account, seat| account if template[seat] == side } }
      unless sides.map(&:sort).sort == expected.map { |unit| unit['accounts'] }.sort
        raise Invalid, :invalid_base_seats
      end
      sides
    end

    def native(game:, options:, people:, template:, unit_size: 2)
      input = Data.freeze_tree(Data.copy({'options' => options, 'people' => people, 'template' => template}))
      options, people, template = input.values_at('options', 'people', 'template')
      template(template, options: options, unit_size: unit_size)
      count = unit_size * 2
      unless people.is_a?(Array) && people.size == count && people.all? { |person| person.is_a?(Hash) } &&
          people.map { |person| person['seat'] }.eql?((0...count).to_a)
        raise Invalid, :invalid_people
      end
      people.each do |person|
        unless person['account'].eql?(Data.account(person['username']).downcase) &&
            Data.text?(person['team']) && person['team'].match?(/\A[A-Za-z0-9_-]{1,64}\z/)
          raise Invalid, :invalid_people
        end
      end
      raise Invalid, :duplicate_account unless people.map { |person| person['account'] }.uniq.size == count
      sides = [0, 1].map { |side| people.each_with_index.filter_map { |person, seat| person if template[seat] == side } }
      unless sides.all? { |side| side.map { |person| person['team'] }.uniq.size == 1 } &&
          sides.map { |side| side.first['team'].downcase }.uniq.size == 2 && !options.key?('team_players')
        raise Invalid, :invalid_membership
      end
      players = people.map { |person| person['username'] }
      unless game.team_size(options, player_count: count).eql?(unit_size) && game.validation_error(options, player_count: count).nil?
        raise Invalid, :unsupported_role_family
      end
      native = game.with_team_assignment(options, players: players, seats: template)
      expected = options.merge('team_seats' => template, 'team_players' => players)
      prepared = game.prepared_team_assignment(native, players: players)
      unless native.eql?(expected) && prepared && [0, 1].all? { |side| prepared.members_for(side).eql?(sides[side].map { |person| person['username'] }) }
        raise Invalid, :invalid_native_payload
      end
      Data.freeze_tree(Data.copy(native))
    end

    def template(value, options:, unit_size: 2)
      raise Invalid, :invalid_options unless options.is_a?(Hash)
      unless unit_size.is_a?(Integer) && unit_size.between?(2, 128) &&
          value.is_a?(Array) && value.size == unit_size * 2 && value.all? { |seat| seat.is_a?(Integer) } &&
          value.sort == [0] * unit_size + [1] * unit_size
        raise Invalid, :invalid_team_template
      end
      if options.key?('team_seats') && !options['team_seats'].eql?(value)
        raise Invalid, :invalid_team_template
      end
      value.dup
    end
  end
end
