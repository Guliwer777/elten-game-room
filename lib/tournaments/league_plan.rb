# encoding: UTF-8
module GameRoomTournaments
  # Lokalny plan turnieju każdy z każdym; kolejność nazw nie przypisuje miejsc ani ról.
  class LeaguePlan
    class Invalid < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    def self.build(participants:, players_per_match:, pairing:, rematch:)
      unless (Array === participants) && participants.length.between?(2, 256)
        raise Invalid, :invalid_participants
      end
      unless participants.all? { |name| (String === name) && name.valid_encoding? &&
        (name.encoding == Encoding::UTF_8 || (name.encoding.ascii_compatible? && name.ascii_only?)) &&
        name.length.between?(1, 64) && !name.match?(/[[:cntrl:]\u2028\u2029]/) &&
        !name.match?(/\A[[:space:]]|[[:space:]]\z/) }
        raise Invalid, :invalid_participants
      end
      unless participants.map(&:downcase).uniq.length == participants.length
        raise Invalid, :invalid_participants
      end
      unless (Integer === players_per_match) && players_per_match.between?(2, 8) &&
        players_per_match <= participants.length
        raise Invalid, :invalid_players_per_match
      end
      raise Invalid, :missing_pairing if nil.equal?(pairing)
      unless (String === pairing) && ['all_combinations', 'balanced_cycle'].include?(pairing)
        raise Invalid, :invalid_pairing
      end
      raise Invalid, :missing_rematch if nil.equal?(rematch)
      raise Invalid, :invalid_rematch unless true.equal?(rematch) || false.equal?(rematch)
      # Najpierw liczba spotkań, bez tworzenia choćby części nadmiernego planu.
      legs = rematch ? 2 : 1
      balanced = 'balanced_cycle' == pairing && players_per_match > 2
      count = participants.length == players_per_match ? 1 : participants.length
      unless balanced
        count = 1
        [players_per_match, participants.length - players_per_match].min.times do |index|
          count = count * (participants.length - index) / (index + 1)
          raise Invalid, :too_many_matches if count * legs > 5000
        end
      end
      raise Invalid, :too_many_matches if count * legs > 5000
      plan = []
      compositions = if balanced
        count.times.map do |start|
          Array.new(players_per_match) { |offset| participants[(start + offset) % participants.length] }
        end
      else
        participants.combination(players_per_match)
      end
      (1..legs).each do |leg|
        compositions.each do |players|
          plan << { 'number' => plan.length + 1, 'players' => players.map(&:dup), 'leg' => leg }
        end
      end
      plan
    end
  end
end
