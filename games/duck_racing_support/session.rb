# frozen_string_literal: true

require_relative "race"
require_relative "private_round"
require_relative "challenge_trace"

module GameRoomDuckRacing
  # Pure durable state. The ordinary game executor supplies authenticated seat
  # and moderator identities; local clients own keys, playback and elapsed
  # input traces. No callback, clock, file or network object belongs here.
  module Session
    IDLE_MS = 90_000
    PULSE_MS = 30_000
    CONCURRENT = %w[ready alive commit reveal attempt].freeze
    INPUTS = %w[start race ready begin alive commit reveal attempt input advance point cancel].freeze
    module_function

    def initial(session_id:, player_count:, laps:, enabled_challenges:, fingerprint:)
      # A saved-game validation has no active native session. Historical begin
      # events carry their original commitment scope; no action can be sent
      # from this read-only, nil-ID projection.
      unless (session_id.nil? || session_id.is_a?(Integer) && session_id.positive?) && player_count.is_a?(Integer) &&
          player_count.between?(2, 8) && laps.is_a?(Integer) && laps.between?(1, 10) &&
          fingerprint.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(fingerprint)
        raise ArgumentError, "Invalid race session"
      end
      unless !Challenges.eligible(player_count: 2, enabled: enabled_challenges).empty? &&
          !Challenges.eligible(player_count: player_count, enabled: enabled_challenges).empty?
        raise ArgumentError, "Select a challenge for duels and the whole group"
      end
      {session_id: session_id, player_count: player_count, laps: laps,
        enabled_challenges: enabled_challenges.dup, fingerprint: fingerprint.dup,
        revision: 0, race: nil, round: nil, last_resolution: nil,
        point_receipt: nil, private_closures: [], notices: []}
    end

    # Caller applies to an isolated candidate and publishes it only on success.
    # An invalid action may not mutate the accepted replay or consume its RNG.
    def apply(state, data, seat:, moderator:, now_ms:, resources: {})
      return false unless data.is_a?(Hash) && data.keys.all? { |key| key.is_a?(String) } &&
        INPUTS.include?(data["action"]) && valid_time?(now_ms) &&
        seat.is_a?(Integer) && seat.between?(0, state[:player_count] - 1)
      return false if state[:race]&.fetch(:phase) == :finished
      return false if data.key?("session") && !(data["session"].is_a?(Integer) && data["session"].positive?)
      action = data["action"]
      independent_swap = action == 'input' && state.dig(:round, :challenge, :kind) == 'sound_order'
      return false unless CONCURRENT.include?(action) || independent_swap || data["revision"] == state[:revision]
      state[:notices] = []
      if action == "start"
        return false unless moderator && state[:race].nil? && data["seed"].is_a?(Integer) && data["seed"] >= 0
        state[:race] = Race.start(player_count: state[:player_count], laps: state[:laps],
          enabled_challenges: state[:enabled_challenges], seed: data["seed"])
        state[:notices] << [:started]
      elsif action == "race"
        return false unless state[:race] && state[:round].nil?
        input = data["input"]
        return false unless input.is_a?(Hash) && (input.keys - %w[kind card target]).empty?
        kind = {"roll" => :roll, "skip" => :skip, "play" => :play}[input["kind"]]
        return false unless kind
        # Passing an automatically skipped turn is an executor operation, not
        # a way for another client to spend this player's frozen turns.
        return false if kind == :skip && !moderator
        acting_seat = kind == :skip ? state[:race][:turn] : seat
        accepted = Race.new(state[:race]).apply(seat: acting_seat, revision: state[:race][:revision],
          action: {kind: kind, card: input["card"], target: input["target"]})
        return false unless accepted
        state[:notices].concat(state[:race][:notices])
        open_challenge(state, now_ms)
      else
        round = state[:round]
        return false unless round && data["challenge"] == round[:challenge][:id]
        return false unless apply_challenge(state, data, seat, moderator, now_ms, resources)
      end
      state[:revision] += 1
      true
    end

    def open_challenge(state, now_ms)
      challenge = state[:race][:challenge]
      return unless challenge
      state[:round] = {
        challenge: copy(challenge), phase: :preparing, ready: {},
        last_seen: challenge[:participants].to_h { |seat| [seat, now_ms] },
        created_at: now_ms, started_at: nil, private: nil, engine: nil, attempts: nil,
        balances: challenge[:participants].to_h { |seat| [seat, state[:race][:racers].fetch(seat)[:feathers]] }
      }
    end
    private_class_method :open_challenge

    def apply_challenge(state, data, seat, moderator, now_ms, resources)
      round = state.fetch(:round)
      challenge = round.fetch(:challenge)
      kind, seats = challenge.values_at(:kind, :participants)
      participant = seats.include?(seat)
      return false if now_ms < round[:created_at]

      accepted = case data["action"]
      when "ready"
        if participant && round[:phase] == :preparing && !round[:ready].key?(seat) && data["fingerprint"] == state[:fingerprint]
          round[:ready][seat] = true
        end
      when "begin"
        if moderator && round[:phase] == :preparing && seats.all? { |member| round[:ready][member] }
          begin_challenge(state, data, now_ms, resources)
          true
        end
      when "alive"
        if participant && now_ms >= round[:last_seen].fetch(seat) + PULSE_MS
          true
        end
      when "commit"
        if participant && round[:phase] == :playing && round[:private]
          PrivateRound.accept_commit(round[:private], seat: seat, value: data["value"], now_ms: now_ms)
        end
      when "reveal"
        if participant && round[:phase] == :playing && round[:private]
          PrivateRound.accept_reveal_page(round[:private], seat: seat, page: data["page"], now_ms: now_ms)
        end
      when "attempt"
        if participant && round[:phase] == :playing && round[:attempts] && !round[:attempts].key?(seat)
          begin
            verifier = TraceVerifier.new(challenge: challenge, balances: round[:balances], resources: resources)
            round[:attempts][seat] = verifier.verify_attempt(seat, data["trace"])
          rescue TraceVerifier::InvalidTrace
            return false
          end
          true
        end
      when "input"
        if participant && round[:phase] == :playing && round[:engine]
          ChallengeEngine.submit(round[:engine], seat: seat, action: data["input"],
            now_ms: now_ms - round[:started_at], resources: resources)
        end
      when "advance"
        moderator && advance(round, now_ms)
      when "point"
        if moderator && round[:phase] == :playing && ChallengeEngine::REALTIME.include?(kind)
          accept_point(state, data["receipt"], now_ms)
        end
      when "cancel"
        if moderator && idle?(round, now_ms)
          cancel(state, :unresponsive, now_ms: now_ms)
          true
        elsif participant && data["reason"] == "technical"
          # A playback/resource/commit-capacity failure is not a made-up loss.
          cancel(state, :technical, now_ms: now_ms)
          true
        end
      end
      return false unless accepted
      if %w[input advance].include?(data["action"]) && round[:engine]
        state[:notices].concat(round[:engine][:model][:notices].to_a)
      end
      round[:last_seen][seat] = [round[:last_seen].fetch(seat, now_ms), now_ms].max if participant
      resolve_ready(state, resources, now_ms) if state[:round]
      true
    end
    private_class_method :apply_challenge

    def begin_challenge(state, data, now_ms, resources)
      round = state.fetch(:round)
      challenge = round.fetch(:challenge)
      kind, seats = challenge.values_at(:kind, :participants)
      round[:phase], round[:started_at] = :playing, now_ms
      round[:last_seen].transform_values! { now_ms }
      if ChallengeEngine::SHARED.include?(kind)
        round[:engine] = ChallengeEngine.start(challenge, resources: resources)
      elsif ChallengeEngine::FIRST_ANSWER.include?(kind)
        round[:attempts] = {}
      elsif !ChallengeEngine::REALTIME.include?(kind)
        # Local models enforce the actual game limits. In particular no
        # overall commit deadline is allowed to cap an ongoing Simon.
        round[:private] = PrivateRound.start(session_id: data.fetch("session", state[:session_id]),
          round_id: challenge[:id].to_s, seats: seats, started_at_ms: now_ms,
          reveal_timeout_ms: IDLE_MS)
      end
      state[:notices] << [:challenge_started, challenge[:id], kind, seats.dup]
      if round[:engine]
        state[:notices].concat(round[:engine][:model][:notices].to_a)
        first = ChallengeEngine.current_turn(round[:engine])
        state[:notices] << [:challenge_turn, first] unless first.nil?
      end
    end
    private_class_method :begin_challenge

    def advance(round, now_ms)
      return false unless round[:phase] == :playing
      if round[:private]
        protocol = round[:private]
        return PrivateRound.close_commits(protocol, now_ms: now_ms) if protocol[:phase] == :collecting
        # A missing upload is a technical cancellation, not an invented zero
        # score. The session's ninety-second inactivity policy handles it.
        false
      elsif round[:engine]
        ChallengeEngine.expire(round[:engine], now_ms: now_ms - round[:started_at])
      else
        false
      end
    end
    private_class_method :advance

    def automatic(state, now_ms:)
      round = state[:round]
      return unless round && valid_time?(now_ms)
      return "cancel" if idle?(round, now_ms)
      if round[:phase] == :preparing
        return "begin" if round[:challenge][:participants].all? { |seat| round[:ready][seat] }
      elsif round[:private]&.fetch(:phase) == :collecting
        protocol = round[:private]
        return "advance" if protocol[:seats].all? { |seat| protocol[:commitments].key?(seat) }
      elsif round[:engine] && ChallengeEngine.expire(copy(round[:engine]), now_ms: now_ms - round[:started_at])
        return "advance"
      end
      nil
    end

    def idle?(round, now_ms)
      # Realtime connection/physics already owns its native recovery protocol;
      # these pulses are only for the ordinary private/sequential challenges.
      return false if round[:phase] == :playing && ChallengeEngine::REALTIME.include?(round[:challenge][:kind])
      # Once the attempt is committed there are no more human decisions.
      # Require real upload progress, not just a responsive UI heartbeat.
      # Each accepted page renews its participant's deadline in PrivateRound.
      if round[:private]&.fetch(:phase) == :revealing
        return true if round[:private][:reveal_deadlines].values.any? { |deadline| now_ms >= deadline }
      end
      round[:last_seen].any? do |seat, time|
        done = round[:attempts]&.key?(seat) || round[:private] && round[:private][:reveals].key?(seat)
        !done && now_ms - time >= IDLE_MS
      end
    end

    def resolve_ready(state, resources, now_ms)
      round = state[:round]
      return unless round
      if round[:attempts] && (round[:attempts].values.any? { |result| result[:correct] } ||
          round[:attempts].length == round[:challenge][:participants].length)
        kind = round[:challenge][:kind]
        results = round[:challenge][:participants].to_h do |seat|
          [seat, round[:attempts].fetch(seat) { ChallengeEngine.missing_result(kind) }]
        end
        result = ChallengeEngine.settlement(kind, balances: round[:balances], results: results)
        complete(state, result, results, now_ms, answer: ChallengeEngine.solution(round[:challenge], resources: resources))
      elsif round[:engine] && ChallengeEngine.finished?(round[:engine])
        results = round[:challenge][:participants].to_h { |seat| [seat, ChallengeEngine.result_for(round[:engine], seat)] }
        result = ChallengeEngine.settlement(round[:challenge][:kind], balances: round[:balances], results: results)
        complete(state, result, results, now_ms)
      elsif round[:private]&.fetch(:phase) == :finished
        verifier = TraceVerifier.new(challenge: round[:challenge], balances: round[:balances], resources: resources)
        resolved = PrivateRound.replay(round[:private], adapter: verifier)
        answer = ChallengeEngine.solution(round[:challenge], resources: resources)
        complete(state, resolved.settlement, resolved.results, now_ms, answer: answer)
      end
    rescue TraceVerifier::InvalidTrace => error
      cancel(state, :invalid_trace, now_ms: now_ms)
      state[:notices] << [:invalid_trace, error.message]
    end
    private_class_method :resolve_ready

    def accept_point(state, receipt, now_ms)
      round, challenge = state[:round], state[:round][:challenge]
      return false unless receipt.is_a?(Hash) && receipt.keys.sort == %w[epoch id kind participants point winner] &&
        receipt["id"] == challenge[:id] && receipt["kind"] == challenge[:kind] &&
        receipt["participants"] == challenge[:participants] && receipt["epoch"].is_a?(String) &&
        !receipt["epoch"].empty? && receipt["point"].is_a?(String)
      match = /\A0:([01])(:timeout)?\z/.match(receipt["point"])
      return false unless match && receipt["winner"].is_a?(Integer) &&
        receipt["winner"] == challenge[:participants].fetch(match[1].to_i)
      # The outer action boundary additionally verifies the current native
      # control epoch. A historical result is replayed in its original epoch.
      result = Settlement.fixed(balances: round[:balances], winner: receipt["winner"], amount: 5)
      state[:point_receipt] = copy(receipt)
      complete(state, result, {receipt["winner"] => {point: true}}, now_ms)
      true
    end
    private_class_method :accept_point

    def complete(state, result, results, now_ms, answer: nil)
      challenge = state[:round][:challenge]
      remember_private_closure(state, cancelled: false)
      state[:last_resolution] = {id: challenge[:id], kind: challenge[:kind], results: copy(results),
        settlement: result, answer: answer}
      state[:notices] << [:challenge_details, challenge[:kind], copy(results), answer]
      unless Race.new(state[:race]).complete_challenge(id: challenge[:id], result: result)
        raise ArgumentError, "Challenge continuation no longer matches the race"
      end
      state[:notices].concat(state[:race][:notices])
      state[:round] = nil
      open_challenge(state, now_ms)
    end
    private_class_method :complete

    def cancel(state, reason, now_ms:)
      round = state[:round]
      return false unless round
      remember_private_closure(state, cancelled: true)
      state[:last_resolution] = {id: round[:challenge][:id], kind: round[:challenge][:kind], cancelled: reason}
      Race.new(state[:race]).cancel_challenge(id: round[:challenge][:id])
      state[:notices].concat(state[:race][:notices])
      state[:round] = nil
      open_challenge(state, now_ms)
      true
    end

    # These small receipts are derived from accepted events, not new server
    # records or copied input traces. They let a recreated worker remove its
    # confirmed local answers even after later challenges have finished.
    def remember_private_closure(state, cancelled:)
      protocol = state.dig(:round, :private)
      return unless protocol
      state[:private_closures] << {session_id: protocol[:session_id], round_id: protocol[:round_id],
        seats: protocol[:seats].dup, commitments: protocol[:commitments].dup, cancelled: cancelled}
    end
    private_class_method :remember_private_closure

    # Called while replaying the accepted roster transition, before processing
    # a new controller's input. A different owner alone is not a seat change.
    def participants_changed(state, seats:, now_ms:)
      return false unless state[:round] && (state[:round][:challenge][:participants] & seats).any?
      state[:round][:last_seen].transform_values! { now_ms }
      state[:notices] = []
      cancel(state, :participant_changed, now_ms: now_ms)
      state[:revision] += 1
      true
    end

    def copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def valid_time?(time)
      time.is_a?(Integer) && time >= 0
    end
    private_class_method :valid_time?
  end
end
