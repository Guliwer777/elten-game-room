# frozen_string_literal: true

require_relative "challenge_engine"

module GameRoomDuckRacing
  # A local, monotonic input trace. It contains accepted edges and playback
  # acknowledgements, not an entry per UI frame. The outer client persists
  # the finished trace through HiddenSubmissions for private challenges; a
  # first-answer challenge publishes it directly for ordered verification.
  class ChallengeTrace
    attr_reader :state, :seat

    def initialize(challenge, seat:, resources: {})
      raise ArgumentError, "A shared challenge uses public actions" if ChallengeEngine::SHARED.include?(challenge[:kind])
      raise ArgumentError, "Participant is not in this challenge" unless challenge.fetch(:participants).include?(seat)
      @state = ChallengeEngine.start(challenge, resources: resources)
      @seat, @resources = seat, resources
      @actions, @finished_at, @last_time = [], nil, 0
    end

    def submit(action, at:)
      return false if finished? || !at.is_a?(Integer) || at < @last_time
      return false unless ChallengeEngine.submit(@state, seat: @seat, action: action, now_ms: at, resources: @resources)

      input = action.to_h { |key, value| [key.to_s, value.is_a?(Symbol) ? value.to_s : value] }
      @actions << {"at" => at, "input" => Marshal.load(Marshal.dump(input))}
      @last_time = at
      @finished_at = at if ChallengeEngine.own_finished?(@state, @seat)
      true
    end

    def tick(at:)
      return false if finished? || !at.is_a?(Integer) || at < @last_time
      changed = ChallengeEngine.expire(@state, now_ms: at)
      @last_time = at
      @finished_at = at if ChallengeEngine.own_finished?(@state, @seat)
      changed
    end

    def finished?
      !@finished_at.nil?
    end

    def snapshot
      raise ArgumentError, "The private attempt is still running" unless finished?
      Marshal.load(Marshal.dump({"actions" => @actions, "finished_at" => @finished_at}))
    end
  end

  # Verifies complete traces by re-running the rules. Private challenges
  # check commitments first; first-answer challenges verify at acceptance.
  # No claimed score is accepted. Player clocks are relative to that player's
  # challenge start; never subtract wall clocks from different computers.
  class TraceVerifier
    class InvalidTrace < ArgumentError; end
    Resolution = Data.define(:results, :settlement)

    def initialize(challenge:, balances:, resources: {})
      @challenge, @balances, @resources = challenge, balances, resources
      if (ChallengeEngine::SHARED + ChallengeEngine::REALTIME).include?(challenge[:kind])
        raise ArgumentError, "This challenge has its own authoritative action path"
      end
      raise ArgumentError, "Incorrect feather balances" unless balances.keys.sort == challenge[:participants].sort
    end

    def replay(traces:, forfeits:)
      forfeits = forfeits.keys if forfeits.is_a?(Hash)
      unless traces.is_a?(Hash) && forfeits.is_a?(Array) && forfeits.uniq == forfeits &&
          (traces.keys & forfeits).empty? && (traces.keys + forfeits).sort == @challenge[:participants].sort
        raise InvalidTrace, "Incomplete participant traces"
      end
      results = traces.to_h { |seat, trace| [seat, verify_trace(seat, trace)] }
      forfeits.each { |seat| results[seat] = ChallengeEngine.missing_result(@challenge[:kind]) }
      settlement = ChallengeEngine.settlement(@challenge[:kind], balances: @balances, results: results, excluded: forfeits)
      Resolution.new(results.freeze, settlement)
    end

    def verify_attempt(seat, trace)
      raise InvalidTrace, "Not a first-answer participant" unless
        ChallengeEngine::FIRST_ANSWER.include?(@challenge[:kind]) && @challenge[:participants].include?(seat)

      verify_trace(seat, trace)
    end

    private

    def verify_trace(seat, trace)
      unless trace.is_a?(Hash) && trace.keys.sort == %w[actions finished_at] && trace["actions"].is_a?(Array) &&
          trace["finished_at"].is_a?(Integer) && trace["finished_at"] >= 0
        raise InvalidTrace, "Malformed private attempt"
      end
      state = ChallengeEngine.start(@challenge, resources: @resources)
      last = 0
      trace["actions"].each do |entry|
        unless entry.is_a?(Hash) && entry.keys.sort == %w[at input] && entry["at"].is_a?(Integer) &&
            entry["at"] >= last && entry["at"] <= trace["finished_at"] && entry["input"].is_a?(Hash)
          raise InvalidTrace, "Malformed challenge input"
        end
        ChallengeEngine.expire(state, now_ms: entry["at"])
        unless ChallengeEngine.submit(state, seat: seat, action: entry["input"], now_ms: entry["at"], resources: @resources)
          raise InvalidTrace, "Rejected challenge input in committed trace"
        end
        last = entry["at"]
      end
      ChallengeEngine.expire(state, now_ms: trace["finished_at"])
      raise InvalidTrace, "Unfinished committed attempt" unless ChallengeEngine.own_finished?(state, seat)
      ChallengeEngine.result_for(state, seat)
    end
  end
end
