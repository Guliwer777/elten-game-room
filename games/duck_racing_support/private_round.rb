# frozen_string_literal: true

require "base64"
require_relative "../../lib/hidden_submissions"
require_relative "../../lib/game_action_payload"
require_relative "private_trace_stream"

module GameRoomDuckRacing
  # Transport/privacy adapter, not a clock, scheduler or challenge model.
  # The owner validates event authors/controllers before passing a seat here.
  # All wire values use existing ActionPlan framing; only local preparation
  # and recovery touch the existing durable hidden-submission vault.
  module PrivateRound
    class InvalidSubmission < ArgumentError; end
    CapacityError = PrivateTraceStream::CapacityError
    class NotResolved < StandardError; end
    class Cancelled < StandardError; end

    COMMIT_ACTION = "duck_commit"
    ACTION_KEYS = %w[kind value press_id repeat other playback_id onsets_ms].freeze
    # A fitting-search window, never a limit on a complete private attempt.
    BYTES_PER_PAGE = 1024

    PreparedSubmission = Struct.new(:envelope, :commit_plan, :reveal_plans, :offsets, :pages, keyword_init: true) do
      def records_needed; 1 + reveal_plans.length; end

      def commit_value; commit_plan.events.first.value.dup; end

      # Data for a shared outer action envelope: encode these objects directly,
      # not the already encoded EventCommands. Recheck the final packet budget
      # if the outer layer adds metadata. Call outside the UI frame.
      def reveal_page(index)
        raise IndexError, "Private page is out of range" unless index.is_a?(Integer) && index >= 0 && index < offsets.length

        Marshal.load(Marshal.dump(pages.fetch(index)))
      end

      def reveal_pages
        offsets.each_index.map { |index| reveal_page(index) }
      end
    end

    module_function

    def start(session_id:, round_id:, seats:, started_at_ms:, commit_deadline_ms: nil, reveal_timeout_ms:, compact: false)
      unless session_id.is_a?(Integer) && session_id.positive? && round_id.is_a?(String) &&
          !round_id.empty? && round_id.valid_encoding? && round_id.bytesize <= 128 &&
          seats.is_a?(Array) && seats.length.between?(2, 8) && seats.uniq.length == seats.length &&
          seats.all? { |seat| seat.is_a?(Integer) && seat >= 0 } && time?(started_at_ms) &&
          (commit_deadline_ms.nil? || (time?(commit_deadline_ms) && commit_deadline_ms >= started_at_ms)) &&
          reveal_timeout_ms.is_a?(Integer) && reveal_timeout_ms.positive?
        raise ArgumentError, "Invalid private challenge setup"
      end
      {
        session_id: session_id, round_id: round_id.dup, seats: seats.dup,
        tag: Digest::SHA256.hexdigest(JSON.generate([session_id, round_id]))[0, 16],
        started_at_ms: started_at_ms, commit_deadline_ms: commit_deadline_ms,
        reveal_timeout_ms: reveal_timeout_ms, phase: :collecting,
        commitments: {}, pages: {}, reveals: {}, forfeits: {}, reveal_deadlines: {}, compact: compact
      }
    end

    # The canonical trace contains actions [{"at" => relative_ms,
    # "input" => accepted_action}] and "finished_at" (local elapsed ms).
    # Its committed representation remains [relative_ms, input]. Only the
    # wire pages change: one durably cached compressed envelope, byte ranges.
    # If preflight fails, no command is returned; the caller must report a
    # technical error/cancel without feather transfers, never truncate input.
    def prepare(state, seat:, user:, trace:, vault:, nonce: nil, available_records: nil, page_builder: nil)
      raise InvalidSubmission, "This private challenge is not collecting answers" unless state[:phase] == :collecting &&
        state[:seats].include?(seat) && !state[:forfeits].key?(seat)
      unless nonce.nil? || (nonce.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(nonce))
        raise InvalidSubmission, "Invalid private answer nonce"
      end

      if state[:compact]
        payload = answer_payload(state, seat, trace)
      else
        inputs, elapsed_ms = compact_trace(trace)
        payload = submission_payload(state, seat, inputs, elapsed_ms)
      end
      previous = vault.reveal(session_id: state[:session_id], round_id: vault_round_id(state), user: user)
      if previous && (!vault.verify(previous) || previous.payload != payload)
        # A previous commit might already be accepted with its acknowledgement
        # still in flight. A finished local attempt cannot be edited/replaced.
        raise InvalidSubmission, "The prepared private answer cannot be changed"
      end
      digest, actual_nonce, normalized = HiddenSubmissions::Commitment.create(payload, nonce: nonce || SecureRandom.hex(32))
      envelope = previous || HiddenSubmissions::Envelope.new(session_id: state[:session_id],
        round_id: vault_round_id(state), user: user, payload: normalized, nonce: actual_nonce, commitment: digest)
      unless vault.verify(envelope) && (!state[:commitments].key?(seat) || state[:commitments][seat] == envelope.commitment)
        raise InvalidSubmission, "The stored answer differs from the accepted commitment"
      end
      stream, cached = local_stream(state, envelope, user: user, vault: vault)
      prepared = build_prepared(state, envelope, stream, page_builder: page_builder)
      check_capacity!(prepared, available_records)
      # Preflight does not create local debris. Both canonical answer and exact
      # compressed bytes must be durable before a commit plan can escape.
      unless previous
        saved = vault.prepare(session_id: state[:session_id], round_id: vault_round_id(state), user: user,
          payload: envelope.payload, nonce: envelope.nonce)
        raise InvalidSubmission, "The private answer changed while preparing" unless saved == envelope
      end
      persist_stream(state, envelope, stream, user: user, vault: vault) unless cached
      prepared
    rescue HiddenSubmissions::StorageError
      # Never remove an older attempt whose commit may have reached the server.
      # A first local preparation has not returned any committable action yet.
      if envelope && !previous && !state[:commitments].key?(seat)
        vault.discard(session_id: state[:session_id], round_id: wire_round_id(envelope), user: user)
        vault.discard(session_id: state[:session_id], round_id: vault_round_id(state), user: user)
      end
      raise
    end

    # A missing/corrupt local envelope does not invent a result or stop the
    # separate reveal timeout. Accepted older versions are recovered by hash.
    def recover(state, seat:, user:, vault:, page_builder: nil)
      envelope = recover_envelope(state, seat: seat, user: user, vault: vault)
      return nil unless envelope

      stream, cached = local_stream(state, envelope, user: user, vault: vault)
      prepared = build_prepared(state, envelope, stream, page_builder: page_builder)
      persist_stream(state, envelope, stream, user: user, vault: vault) unless cached
      prepared
    rescue InvalidSubmission, ArgumentError, TypeError, KeyError
      nil
    end

    # The executor needs one missing page, not a freshly compressed plan for
    # the whole immutable attempt. Full preflight still happens before commit;
    # this page is budgeted again using the current revision and native limit.
    def recover_next_reveal_page(state, seat:, user:, vault:, page_builder: nil)
      return nil unless state[:phase] == :revealing && !state[:reveals].key?(seat)

      envelope = recover_envelope(state, seat: seat, user: user, vault: vault)
      return nil unless envelope && state[:commitments][seat] == envelope.commitment

      accepted, offset = state[:pages].fetch(seat, {}), 0
      while (received = accepted[offset])
        count = PrivateTraceStream.page_size(received)
        return nil unless count.positive?
        offset += count
      end
      stream, cached = local_stream(state, envelope, user: user, vault: vault)
      return nil if offset >= stream.bytes.bytesize

      page, = build_reveal_page(state, envelope, stream, offset, page_builder: page_builder)
      persist_stream(state, envelope, stream, user: user, vault: vault) unless cached
      copy(page)
    rescue InvalidSubmission, ArgumentError, TypeError, KeyError
      nil
    end

    def recover_envelope(state, seat:, user:, vault:)
      return nil unless [:collecting, :revealing].include?(state[:phase]) && state[:seats].include?(seat) &&
        !state[:forfeits].key?(seat) && !state[:reveals].key?(seat)

      envelope = vault.reveal(session_id: state[:session_id], round_id: vault_round_id(state), user: user,
        commitment: state[:commitments][seat])
      return nil unless envelope && envelope.payload.is_a?(Hash) && vault.verify(envelope)
      return nil if state[:commitments].key?(seat) && state[:commitments][seat] != envelope.commitment

      expected = canonical_payload(state, seat, envelope.payload)
      return nil unless expected == envelope.payload

      validate_envelope!(envelope)
      envelope
    end
    private_class_method :recover_envelope

    # Re-budgeting just before writing can split a pending byte range, without
    # recompressing the source or changing an already accepted prefix.
    def shrink_reveal_page(page)
      PrivateTraceStream.shrink_page(page)
    end

    def reveal_page_size(page)
      PrivateTraceStream.page_size(page)
    end

    def next_reveal_plan(state, prepared)
      index = next_reveal_index(state, prepared)
      index && prepared.reveal_plans[index]
    end

    def next_reveal_page(state, prepared)
      index = next_reveal_index(state, prepared)
      index && prepared.reveal_page(index)
    end

    def next_reveal_index(state, prepared)
      return nil unless state[:phase] == :revealing

      payload = prepared.envelope.payload
      seat = payload["seat"]
      return nil unless payload_scope?(state, payload, seat) &&
        state[:commitments][seat] == prepared.envelope.commitment &&
        !state[:reveals].key?(seat) && !state[:forfeits].key?(seat)

      accepted = state[:pages].fetch(seat, {})
      prepared.offsets.index { |offset| !accepted.key?(offset) }
    end
    private_class_method :next_reveal_index

    def accept_commit(state, seat:, value:, now_ms:)
      return false unless state[:phase] == :collecting && state[:seats].include?(seat) &&
        !state[:commitments].key?(seat) && !state[:forfeits].key?(seat) &&
        time?(now_ms) && now_ms >= state[:started_at_ms] &&
        (!state[:commit_deadline_ms] || now_ms < state[:commit_deadline_ms])
      digest = decode_commitment(state, value)
      return false unless digest

      state[:commitments][seat] = digest
      true
    end

    # Explicit owner transition. Simon supplies no overall commit deadline;
    # its players finish locally, or the lifecycle explicitly forfeits a
    # disconnected seat. This method never expires local challenge models.
    def close_commits(state, now_ms:)
      return false unless state[:phase] == :collecting && time?(now_ms) && now_ms >= state[:started_at_ms]
      complete = state[:seats].all? { |seat| state[:commitments].key?(seat) || state[:forfeits].key?(seat) }
      return false unless complete || (state[:commit_deadline_ms] && now_ms >= state[:commit_deadline_ms])

      state[:seats].each do |seat|
        state[:forfeits][seat] = :commit_timeout unless state[:commitments].key?(seat) || state[:forfeits].key?(seat)
      end
      state[:phase], state[:revealing_at_ms] = :revealing, now_ms
      state[:commitments].each_key do |seat|
        state[:reveal_deadlines][seat] = now_ms + state[:reveal_timeout_ms] unless state[:forfeits].key?(seat)
      end
      finish_if_resolved(state)
      true
    end

    def reveal_action(state)
      "duck_reveal_#{state[:tag]}"
    end

    # Decode atomic page plans with the existing bounded codec. The callback
    # still resolves the authenticated event author to an authorized seat.
    def each_reveal_page(state, events:, repository:, session:, &block)
      return enum_for(__method__, state, events: events, repository: repository, session: session) unless block

      GameRoomActionPayload.each(events, reveal_action(state), repository, session, &block)
    end

    def accept_reveal_page(state, seat:, page:, now_ms:)
      return false unless pending_reveal?(state, seat, now_ms)
      page = normalized_page(state, seat, page)
      return false unless page

      received = state[:pages].fetch(seat, {})
      return false if received.key?(page["offset"])
      if !received.empty?
        reference = received.values.first
        return false unless %w[version codec total unpacked_bytes].all? { |key| reference[key] == page[key] }
        return false if received.values.any? { |existing| overlapping?(page, existing) }
      end
      combined = received.merge(page["offset"] => page)
      disclosed = complete_payload(state, seat, combined)
      if disclosed
        payload = disclosed.fetch("payload")
        return false unless HiddenSubmissions::Commitment.valid?(payload: payload, nonce: disclosed.fetch("nonce"), commitment: state[:commitments][seat])
        state[:reveals][seat] = payload
        state[:pages].delete(seat)
        state[:reveal_deadlines].delete(seat)
      else
        state[:pages][seat] = combined
        # Progress extends only this participant's idle timeout. A retry,
        # duplicate or invalid page cannot keep another participant waiting.
        state[:reveal_deadlines][seat] = [state[:reveal_deadlines][seat], now_ms + state[:reveal_timeout_ms]].max
      end
      finish_if_resolved(state)
      true
    rescue InvalidSubmission, PrivateTraceStream::InvalidStream, CapacityError
      false
    end

    def expire_reveals(state, now_ms:)
      return false unless state[:phase] == :revealing && time?(now_ms)

      expired = state[:reveal_deadlines].select { |_seat, deadline| now_ms >= deadline }.keys
      expired.each { |seat| forfeit(state, seat: seat, reason: :reveal_timeout) }
      !expired.empty?
    end

    # Call only for an authoritative lifecycle decision, not a score reported
    # by a peer. A completed, verified reveal cannot be forfeited afterward.
    def forfeit(state, seat:, reason:)
      return false unless [:collecting, :revealing].include?(state[:phase]) && state[:seats].include?(seat) &&
        !state[:reveals].key?(seat) && !state[:forfeits].key?(seat)
      raise ArgumentError, "Missing forfeit reason" unless reason.is_a?(Symbol) || (reason.is_a?(String) && !reason.empty?)

      state[:forfeits][seat] = reason.is_a?(String) ? reason.dup : reason
      state[:pages].delete(seat)
      state[:reveal_deadlines].delete(seat)
      finish_if_resolved(state)
      true
    end

    def cancel(state, reason:)
      # A fully revealed protocol still needs model verification. A technical
      # failure in that step cancels the challenge, never awards a fake loss.
      return false if state[:phase] == :cancelled
      raise ArgumentError, "Missing cancellation reason" unless reason.is_a?(String) && !reason.empty?

      state[:phase], state[:cancellation] = :cancelled, reason.dup
      state[:pages].clear
      state[:reveals].clear
      state[:reveal_deadlines].clear
      true
    end

    # The adapter replays accepted local input using the actual challenge
    # model. No peer score, rank or success flag is present in this contract.
    # Forfeits stay separate from legitimate gameplay timeout traces.
    def replay(state, adapter:)
      raise Cancelled, state[:cancellation] if state[:phase] == :cancelled
      raise NotResolved, "Private challenge has not finished revealing" unless state[:phase] == :finished

      if state[:compact]
        return adapter.replay(answers: state[:reveals].transform_values { |payload| copy(payload['answer']) },
          forfeits: copy(state[:forfeits]))
      end

      traces = state[:reveals].to_h do |seat, payload|
        actions = payload["trace"].map { |at, input| {"at" => at, "input" => copy(input)} }
        [seat, {"actions" => actions, "finished_at" => payload["elapsed_ms"]}]
      end
      adapter.replay(traces: traces, forfeits: copy(state[:forfeits]))
    end

    def public_view(state)
      {
        phase: state[:phase], round_id: state[:round_id].dup, seats: state[:seats].dup,
        submitted: state[:seats].to_h { |seat| [seat, state[:commitments].key?(seat)] },
        revealed: state[:seats].to_h { |seat| [seat, state[:reveals].key?(seat)] },
        forfeits: copy(state[:forfeits]), cancellation: state[:cancellation]&.dup
      }
    end

    def discard_local(state, seat:, user:, vault:)
      return false unless state[:reveals].key?(seat) || state[:forfeits].key?(seat) || state[:phase] == :cancelled

      envelope = vault.reveal(session_id: state[:session_id], round_id: vault_round_id(state), user: user,
        commitment: state[:commitments][seat])
      commitment = envelope&.commitment || state[:commitments][seat]
      return false unless commitment
      discard_confirmed(session_id: state[:session_id], round_id: state[:round_id],
        user: user, commitment: commitment, vault: vault)
    rescue HiddenSubmissions::StorageError
      false
    end

    # The session removes its private model after resolving a challenge. Its
    # executor may retain this small, locally prepared identity, and call here
    # only after that exact round has an accepted resolution. A planned reveal,
    # stale snapshot or an uncertain commit is not confirmation.
    def discard_confirmed(session_id:, round_id:, user:, commitment:, vault:)
      return false unless session_id.is_a?(Integer) && session_id.positive? &&
        round_id.is_a?(String) && !round_id.empty? &&
        commitment.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(commitment)

      canonical_id, wire_id = "duck:#{round_id}", "duck-wire-v2:#{commitment}"
      envelope = vault.reveal(session_id: session_id, round_id: canonical_id, user: user)
      # Do not delete a different current envelope through an older version's
      # digest. Normal Duck preparations are immutable, including lost acks.
      return false if envelope && envelope.commitment != commitment
      cached = vault.reveal(session_id: session_id, round_id: wire_id, user: user)
      return true unless envelope || cached
      wire_removed = cached && vault.discard(session_id: session_id, round_id: wire_id, user: user)
      # Retain the canonical lookup until its auxiliary bytes can be removed;
      # otherwise a transient cleanup failure could orphan their cache key.
      return false if cached && !wire_removed
      !envelope || vault.discard(session_id: session_id, round_id: canonical_id, user: user)
    rescue HiddenSubmissions::StorageError
      false
    end

    def cleanup_confirmed(session_id:, user:, receipts:, vault:)
      proofs = receipts.select { |receipt| receipt[:session_id] == session_id }
        .to_h { |receipt| [receipt[:round_id], receipt] }
      complete = true
      vault.envelopes(session_id: session_id, user: user, round_prefix: "duck:").each do |envelope|
        payload = envelope.payload
        next unless payload.is_a?(Hash) && payload["session"] == session_id &&
          envelope.round_id == "duck:#{payload['round']}" && vault.verify(envelope)
        proof = proofs[payload["round"]]
        next unless proof && proof[:seats].include?(payload["seat"])
        expected = proof[:commitments][payload["seat"]]
        next unless expected == envelope.commitment || (expected.nil? && proof[:cancelled])
        begin
          # A cancellation may have no accepted commit. Its local envelope
          # still has to be a valid attempt in this exact closed scope.
          next unless payload == canonical_payload(proof, payload['seat'], payload)
        rescue InvalidSubmission
          next
        end
        removed = discard_confirmed(session_id: session_id, round_id: payload["round"],
          user: user, commitment: envelope.commitment, vault: vault)
        complete = false unless removed
      end
      complete
    rescue HiddenSubmissions::StorageError
      false
    end

    def submission_payload(state, seat, trace, elapsed_ms)
      raise InvalidSubmission, "Invalid private input time" unless time?(elapsed_ms)
      { "version" => 1, "session" => state[:session_id], "round" => state[:round_id].dup,
        "seat" => seat, "elapsed_ms" => elapsed_ms, "trace" => normalize_trace(trace, elapsed_ms) }
    end
    private_class_method :submission_payload

    def answer_payload(state, seat, answer)
      valid = answer.is_a?(Hash) && answer.size == 1 && case answer.keys.first
      when 'guesses' then answer['guesses'].is_a?(Array) && answer['guesses'].length <= 10 &&
        answer['guesses'].all? { |value| value.is_a?(Integer) && value.between?(1, 999) }
      when 'choice' then [nil, 'rock', 'paper', 'scissors'].include?(answer['choice'])
      when 'answer' then answer['answer'].nil? || answer['answer'].is_a?(Integer) && answer['answer'].between?(0, 3)
      else false
      end
      raise InvalidSubmission, 'Invalid compact private answer' unless valid
      {'version' => 2, 'session' => state[:session_id], 'round' => state[:round_id].dup,
        'seat' => seat, 'answer' => copy(answer)}
    end
    private_class_method :answer_payload

    def canonical_payload(state, seat, payload)
      state[:compact] ? answer_payload(state, seat, payload['answer']) :
        submission_payload(state, seat, payload['trace'], payload['elapsed_ms'])
    end
    private_class_method :canonical_payload

    def compact_trace(trace)
      unless trace.is_a?(Hash) && trace.keys.all? { |key| key.is_a?(String) } &&
          trace.keys.sort == %w[actions finished_at] && trace["actions"].is_a?(Array)
        raise InvalidSubmission, "Invalid canonical private trace"
      end
      inputs = trace["actions"].map do |entry|
        unless entry.is_a?(Hash) && entry.keys.all? { |key| key.is_a?(String) } && entry.keys.sort == %w[at input]
          raise InvalidSubmission, "Invalid canonical private input"
        end
        [entry["at"], entry["input"]]
      end
      [inputs, trace["finished_at"]]
    end
    private_class_method :compact_trace

    def normalize_trace(trace, elapsed_ms)
      raise InvalidSubmission, "Private input trace must be an array" unless trace.is_a?(Array)

      previous_time, previous_press = 0, -1
      trace.map do |entry|
        unless entry.is_a?(Array) && entry.length == 2 && time?(entry[0]) && entry[0].between?(previous_time, elapsed_ms)
          raise InvalidSubmission, "Invalid private input order"
        end
        action = normalize_action(entry[1])
        if action.key?("press_id") && !%w[playback_started playback_finished].include?(action["kind"])
          raise InvalidSubmission, "Duplicate private input press" unless action["press_id"] > previous_press
          previous_press = action["press_id"]
        end
        previous_time = entry[0]
        [entry[0], action]
      end
    end
    private_class_method :normalize_trace

    def normalize_action(action)
      unless action.is_a?(Hash) && action.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
          action.keys.map(&:to_s).uniq.length == action.length && (action.keys.map(&:to_s) - ACTION_KEYS).empty?
        raise InvalidSubmission, "Invalid private input fields"
      end
      result = action.to_h { |key, value| [key.to_s, value.is_a?(String) ? value.dup : value] }
      kind = result["kind"]
      unless (kind.is_a?(String) || kind.is_a?(Symbol)) && kind.to_s.valid_encoding? && /\A[a-z_]{1,32}\z/.match?(kind.to_s)
        raise InvalidSubmission, "Invalid private input kind"
      end
      result["kind"] = kind.to_s
      %w[press_id playback_id].each do |key|
        raise InvalidSubmission, "Invalid private input identity" if result.key?(key) && !time?(result[key])
      end
      raise InvalidSubmission, "Repeated key is not a new private input" if result.key?("repeat") && result["repeat"] != false
      %w[value other].each do |key|
        value = result[key]
        unless value.nil? || value.is_a?(Integer) || (value.is_a?(String) && value.valid_encoding?)
          raise InvalidSubmission, "Invalid private input value"
        end
      end
      if result.key?("onsets_ms")
        onsets = result["onsets_ms"]
        unless result["kind"] == "playback_finished" && onsets.is_a?(Array) &&
            onsets.length.between?(6, 10) && onsets.all? { |time| time?(time) }
          raise InvalidSubmission, "Invalid rhythm playback times"
        end
        result["onsets_ms"] = onsets.dup
      end
      result
    end
    private_class_method :normalize_action

    def build_prepared(state, envelope, stream, page_builder: nil)
      validate_envelope!(envelope)
      plans, offsets, pages, offset = [], [], [], 0
      loop do
        page, plan = build_reveal_page(state, envelope, stream, offset, page_builder: page_builder)
        plans << plan
        offsets << offset
        pages << page
        offset += PrivateTraceStream.page_size(page)
        break if offset >= stream.bytes.bytesize
      end
      digest = Base64.strict_encode64([envelope.commitment].pack("H*"))
      commit = GameRoomGames::ActionPlan.single(action: COMMIT_ACTION, value: "#{state[:tag]}:#{digest}")
      PreparedSubmission.new(envelope: envelope, commit_plan: commit, reveal_plans: plans.freeze,
        offsets: offsets.freeze, pages: pages.freeze).freeze
    end
    private_class_method :build_prepared

    def validate_envelope!(envelope)
      unless /\A[0-9a-f]{64}\z/.match?(envelope.nonce.to_s) && /\A[0-9a-f]{64}\z/.match?(envelope.commitment.to_s)
        raise InvalidSubmission, "Invalid private answer envelope"
      end
    end
    private_class_method :validate_envelope!

    def build_reveal_page(state, envelope, stream, offset, page_builder: nil)
      payload = envelope.payload
      accepted = state[:pages].fetch(payload.fetch("seat"), {})
      received = accepted[offset]
      # A changed native byte limit, revision or controller epoch may split
      # the remaining trace differently. Keep every accepted boundary and
      # only repartition gaps; otherwise a retry can overlap an earlier page.
      if received
        unless received == PrivateTraceStream.page(stream, payload, offset, PrivateTraceStream.page_size(received))
          raise InvalidSubmission, "The stored stream differs from an accepted page"
        end
        return [copy(received), GameRoomGames::ActionPlan.new(events: GameRoomActionPayload.commands(reveal_action(state), received))]
      end
      next_received = accepted.keys.select { |start| start > offset }.min || stream.bytes.bytesize
      maximum = [BYTES_PER_PAGE, next_received - offset].min
      fitting = lambda do |count|
        page = PrivateTraceStream.page(stream, payload, offset, count)
        begin
          plan = page_builder ? page_builder.call(page) :
            GameRoomGames::ActionPlan.new(events: GameRoomActionPayload.commands(reveal_action(state), page))
          [page, plan]
        rescue ArgumentError
          nil
        end
      end
      best = fitting.call(maximum)
      return best if best

      best = fitting.call(1)
      raise CapacityError, "A private stream byte cannot fit in an event page" unless best

      # Bounded search (not one compression for every possible byte length).
      # Exact native budgeting is checked for every candidate actually used.
      lower, upper = 1, maximum - 1
      while lower < upper
        candidate = (lower + upper + 1) / 2
        if (result = fitting.call(candidate))
          best, lower = result, candidate
        else
          upper = candidate - 1
        end
      end
      # Compressed sizes are not strictly monotonic. A small forward scan can
      # recover nearby larger fits without unbounded exhaustive compression.
      ((lower + 1)..[lower + 16, maximum - 1].min).each do |count|
        best = result if (result = fitting.call(count))
      end
      best
    end
    private_class_method :build_reveal_page

    def check_capacity!(prepared, available_records)
      return if available_records.nil?
      raise ArgumentError, "Invalid event-record budget" unless time?(available_records)
      raise CapacityError, "The private trace needs #{prepared.records_needed} records; only #{available_records} remain" if prepared.records_needed > available_records
    end
    private_class_method :check_capacity!

    def decode_commitment(state, value)
      return nil unless value.is_a?(String) && value.valid_encoding? && value.length <= GameRoomEventProtocol::MAX_VALUE_LENGTH
      prefix = "#{state[:tag]}:"
      return nil unless value.start_with?(prefix)
      encoded = value.delete_prefix(prefix)
      return nil unless /\A[A-Za-z0-9+\/]{43}=\z/.match?(encoded)
      binary = Base64.strict_decode64(encoded)
      return nil unless binary.bytesize == 32 && Base64.strict_encode64(binary) == encoded
      binary.unpack1("H*")
    rescue ArgumentError
      nil
    end
    private_class_method :decode_commitment

    def pending_reveal?(state, seat, now_ms)
      state[:phase] == :revealing && state[:commitments].key?(seat) && !state[:reveals].key?(seat) &&
        !state[:forfeits].key?(seat) && time?(now_ms) && now_ms >= state[:revealing_at_ms] &&
        now_ms < state[:reveal_deadlines].fetch(seat)
    end
    private_class_method :pending_reveal?

    def payload_scope?(state, payload, seat)
      payload.is_a?(Hash) && payload["version"] == (state[:compact] ? 2 : 1) && payload["session"] == state[:session_id] &&
        payload["round"] == state[:round_id] && payload["seat"] == seat && state[:seats].include?(seat)
    end
    private_class_method :payload_scope?

    def normalized_page(state, seat, page)
      PrivateTraceStream.normalize_page(page, session_id: state[:session_id], round_id: state[:round_id], seat: seat)
    end
    private_class_method :normalized_page

    def overlapping?(first, second)
      first["offset"] < second["offset"] + PrivateTraceStream.page_size(second) &&
        second["offset"] < first["offset"] + PrivateTraceStream.page_size(first)
    end
    private_class_method :overlapping?

    def complete_payload(state, seat, pages)
      offset = 0
      ordered = pages.sort_by(&:first).map(&:last)
      ordered.each do |page|
        return nil unless page["offset"] == offset
        offset += PrivateTraceStream.page_size(page)
      end
      return nil unless offset == ordered.first["total"]

      stream = PrivateTraceStream::Stream.new(bytes: ordered.map { |page| PrivateTraceStream.page_bytes(page) }.join,
        unpacked_bytes: ordered.first["unpacked_bytes"], codec: ordered.first["codec"])
      disclosed = PrivateTraceStream.decode(stream)
      payload = disclosed.fetch("payload")
      unless payload_scope?(state, payload, seat) &&
          payload == canonical_payload(state, seat, payload)
        raise InvalidSubmission, "The disclosed private answer has the wrong scope or shape"
      end
      disclosed
    end
    private_class_method :complete_payload

    def local_stream(state, envelope, user:, vault:)
      cached = vault.reveal(session_id: state[:session_id], round_id: wire_round_id(envelope), user: user)
      if cached
        raise InvalidSubmission, "The stored private stream is damaged" unless vault.verify(cached)
        stream = PrivateTraceStream.from_cache(cached.payload, envelope)
      else
        unless state[:pages].fetch(envelope.payload.fetch("seat"), {}).empty?
          raise CapacityError, "The accepted private stream cannot be recovered on this device"
        end
        stream = PrivateTraceStream.encode(envelope)
      end
      state[:pages].fetch(envelope.payload.fetch("seat"), {}).each_value do |page|
        expected = PrivateTraceStream.page(stream, envelope.payload, page.fetch("offset"), PrivateTraceStream.page_size(page))
        raise InvalidSubmission, "The stored stream differs from an accepted page" unless page == expected
      end
      [stream, !cached.nil?]
    end
    private_class_method :local_stream

    def persist_stream(state, envelope, stream, user:, vault:)
      payload = PrivateTraceStream.cache_payload(stream, envelope.commitment)
      saved = vault.prepare(session_id: state[:session_id], round_id: wire_round_id(envelope), user: user,
        payload: payload, nonce: envelope.nonce)
      unless saved.payload == payload && vault.verify(saved)
        raise InvalidSubmission, "The private stream changed while preparing"
      end
    end
    private_class_method :persist_stream

    def finish_if_resolved(state)
      return unless state[:phase] == :revealing
      state[:phase] = :finished if state[:seats].all? { |seat| state[:reveals].key?(seat) || state[:forfeits].key?(seat) }
    end
    private_class_method :finish_if_resolved

    def time?(value); value.is_a?(Integer) && value >= 0; end
    def vault_round_id(state); "duck:#{state[:round_id]}"; end
    def wire_round_id(envelope); "duck-wire-v2:#{envelope.commitment}"; end
    def copy(value); Marshal.load(Marshal.dump(value)); end
    private_class_method :time?, :vault_round_id, :wire_round_id, :copy
  end
end
