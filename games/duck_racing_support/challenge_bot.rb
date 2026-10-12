# frozen_string_literal: true

require_relative "challenge_trace"
require_relative "numeric_bot"

module GameRoomDuckRacing
  # Plans input, not scores. The caller keeps a private trace local until its
  # elapsed time, commits it, and reveals it through the ordinary protocol.
  # There is no clock, thread, network call or second bot executor here.
  module ChallengeBot
    class PlanningError < StandardError; end

    PRIVATE_TYPES = (Challenges::BY_ID.keys - ChallengeEngine::SHARED - ChallengeEngine::REALTIME).freeze
    MEMORY_POSITIONS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].freeze
    module_function

    # seed is the bot's decision seed, not the challenge's secret seed.
    # Prepared word resources contain small candidate pools; no full lexicon
    # scan or dictionary construction takes place while planning an answer.
    def plan(challenge, seat:, seed:, resources: {}, delay_ms: 0)
      unless challenge.is_a?(Hash) && PRIVATE_TYPES.include?(challenge[:kind]) &&
          seat.is_a?(Integer) && challenge.fetch(:participants).include?(seat) && seed.is_a?(Integer)
        raise ArgumentError, "Invalid private challenge bot setup"
      end
      validate_delay(delay_ms)
      Planner.new(challenge, seat: seat, seed: seed, resources: resources, delay_ms: delay_ms).run
    end

    # Start with {} for each new challenge. Feed every accepted public view,
    # including the other player's first and second reveal, in event order.
    # This remembers at most ten heard positions, not the concealed board.
    def observe(view, memory: {})
      old_tones = memory.fetch(:tones, {})
      tones = old_tones.select do |position, tone|
        position.is_a?(Integer) && MEMORY_POSITIONS.include?(position) &&
          tone.is_a?(Integer) && tone.between?(1, 5)
      end
      serial = memory.fetch(:serial, 0)
      serial = 0 unless serial.is_a?(Integer) && serial >= 0
      return {tones: tones, serial: serial} unless view[:type] == "sound_memory"

      public = view.fetch(:public)
      current_serial = public.fetch(:sound_serial)
      return {tones: tones, serial: serial} if current_serial < serial

      heard = public.fetch(:revealed).dup
      heard << public[:sound_event] if public[:sound_event] && current_serial > serial
      heard.each do |event|
        position, tone = event.values_at(:position, :tone)
        if position.is_a?(Integer) && MEMORY_POSITIONS.include?(position) && tone.is_a?(Integer) && tone.between?(1, 5)
          tones[position] = tone
        end
      end
      public.fetch(:removed).each { |position| tones.delete(position) }
      {tones: tones, serial: current_serial}
    end

    # A proposal for the existing executor. Repeated planning with the same
    # event/press identity is deterministic and does not mutate view or memory.
    # The caller still revalidates the challenge, controller, turn and deadline.
    def choose_sequential(view, seat:, seed:, memory: {}, press_id:, delay_ms: 0)
      validate_delay(delay_ms)
      unless seed.is_a?(Integer) && press_id.is_a?(Integer) && press_id.positive?
        raise ArgumentError, "Invalid sequential bot decision identity"
      end
      return nil unless view.is_a?(Hash) && ChallengeEngine::SHARED.include?(view[:type]) &&
        seat.is_a?(Integer) && !view[:finished]

      participants = view[:participants] || view[:seats]
      return nil unless participants.include?(seat)

      random = Random.new(seed ^ ((seat + 1) * 1_000_003) ^ (press_id * 97_409))
      choice = if NumericChallenges::TURN_TYPES.include?(view[:type])
        action = NumericBot.choose(view, seat: seat, random: random)
        return nil unless action
        {action: action.merge(press_id: press_id), delay_ms: NumericBot.reaction_ms(view) + random.rand(400), memory: observe(view, memory: memory)}
      elsif view[:type] == 'sound_order'
        # These are this seat's audible pitches, not another player's draft.
        # Allow time to listen to all eight before the first exchange.
        values = view.fetch(:own).fetch(:arrangement)
        first = values.each_index.find { |index| values[index] != index + 1 }
        return nil unless first
        {action: {kind: :swap, value: first + 1, other: values.index(first + 1) + 1, press_id: press_id},
          delay_ms: (press_id == 1 ? 4_000 : 0) + random.rand(650..1_850), memory: {}}
      else
        public = view.fetch(:public)
        return nil unless public[:turn] == seat
        known = observe(view, memory: memory)
        positions = MEMORY_POSITIONS - public.fetch(:removed) - public.fetch(:revealed).map { |entry| entry[:position] }
        return nil if positions.empty?
        candidates = memory_candidates(positions, known.fetch(:tones), public.fetch(:revealed))
        position = candidates.fetch(random.rand(candidates.length))
        {action: {kind: :reveal, value: position, press_id: press_id}, delay_ms: random.rand(700..1_600), memory: known}
      end
      choice.merge(delay_ms: choice[:delay_ms] + delay_ms)
    end

    def validate_delay(value)
      raise ArgumentError, 'Invalid bot delay' unless value.is_a?(Integer) && value.between?(0, 5_000)
    end
    private_class_method :validate_delay

    def memory_candidates(positions, tones, revealed)
      if revealed.length == 1
        matches = positions.select { |position| tones[position] == revealed.first[:tone] }
        return matches unless matches.empty?
      else
        pairs = positions.select { |position| tones.key?(position) }.group_by { |position| tones[position] }
        matches = pairs.values.select { |group| group.length == 2 }.flatten
        return matches unless matches.empty?
      end
      unknown = positions.reject { |position| tones.key?(position) }
      unknown.empty? ? positions : unknown
    end
    private_class_method :memory_candidates

    class Planner
      # A guard against a broken planner, never a limit on a human's Simon.
      MAX_INPUTS = 512

      def initialize(challenge, seat:, seed:, resources:, delay_ms:)
        @challenge, @seat, @resources = challenge, seat, resources
        @delay_ms = delay_ms
        @trace = ChallengeTrace.new(challenge, seat: seat, resources: resources)
        @random = Random.new(seed ^ ((seat + 1) * 1_000_003))
        @now, @press_id, @input_count = 0, 0, 0
      end

      def run
        wait(0)
        unless @trace.finished?
          case @challenge.fetch(:kind)
          when *NumericChallenges::TYPES.keys then numeric
          when "count_ducks" then count_ducks
          when "rhythm" then rhythm
          when "simon" then simon
          when "hit_duck" then hit_duck
          when "quiz" then quiz
          else raise PlanningError, "Missing private challenge bot strategy"
          end
        end
        raise PlanningError, "The planned private attempt did not finish" unless @trace.finished?
        @trace.snapshot
      end

      private

      def view
        ChallengeEngine.view(@trace.state, seat: @seat)
      end

      def stimulus
        ChallengeEngine.stimulus(@trace.state, seat: @seat)
      end

      def wait(at)
        raise PlanningError, "Bot input time moved backwards" if at < @now
        @trace.tick(at: at)
        @now = at
      end

      def input(action, at:, pause: true)
        acknowledgement = [:playback_finished, :playback_started].include?(action[:kind])
        if pause && !acknowledgement
          # Delay actual decisions, not just publication of an already scored
          # result. Keep the normal one-second deadline margin, like Base bots.
          # Playback and the spacing of rhythm beats are not thinking pauses.
          current = view
          deadline = current[:deadline_ms] || current.dig(:own, :deadline_ms)
          extra = deadline ? [@delay_ms, [deadline - at - 1_000, 0].max].min : @delay_ms
          at += extra
        end
        wait(at) # Match TraceVerifier's expiry-before-input ordering.
        return false if @trace.finished?
        @input_count += 1
        raise PlanningError, "Private bot planner exceeded its input budget" if @input_count > MAX_INPUTS
        unless acknowledgement
          @press_id += 1
          action = action.merge(press_id: @press_id)
        end
        unless @trace.submit(action, at: at)
          raise PlanningError, "Rejected planned #{@challenge[:kind]} input #{action[:kind]}"
        end
        true
      end

      def after(milliseconds, jitter = 0)
        @now + milliseconds + (jitter.positive? ? @random.rand(jitter) : 0)
      end

      # Only pending audio is heard. End acknowledgement follows its full
      # duration, so the response timer never starts before the stimulus ends.
      def listen(playback = stimulus)
        raise PlanningError, "Missing audio stimulus" unless playback
        finish = playback[:requested_ms] + playback[:events].map { |event| event[:offset_ms] + event[:duration_ms] }.max
        input({kind: :playback_finished, playback_id: playback[:id]}, at: [@now, finish].max + @random.rand(20..80))
        playback[:events]
      end

      def numeric
        until @trace.finished?
          current = view
          action = NumericBot.choose(current, seat: @seat, random: @random, race_snapshot: @challenge[:race_snapshot])
          if action
            input(action, at: after(NumericBot.reaction_ms(current), 500))
          else
            wait(current.fetch(:deadline_ms))
          end
        end
      end

      def count_ducks
        count = listen.length
        wrong = @random.rand(100) < 18
        input({kind: :answer, value: wrong ? count + (@random.rand(2).zero? ? -1 : 1) : count}, at: after(700, 1_200))
        return if @trace.finished?
        input({kind: :replay}, at: after(350, 450))
        count = listen.length
        input({kind: :answer, value: count}, at: after(650, 700)) unless @trace.finished?
      end

      def rhythm
        events = listen
        if @random.rand(100) < 15
          input({kind: :replay}, at: after(350, 400))
          events = listen
        end
        return if @trace.finished?
        input({kind: :begin}, at: after(550, 650))
        events.each_with_index do |event, index|
          interval = index.zero? ? 300 : event[:offset_ms] - events[index - 1][:offset_ms]
          tone = @random.rand(100) < 8 ? (event[:tone] == "f" ? "j" : "f") : event[:tone]
          input({kind: :tone, value: tone}, at: @now + [100, interval + @random.rand(-170..170)].max, pause: false)
        end
      end

      def simon
        memory_limit = @random.rand(8..16)
        until @trace.finished?
          heard = listen
          wrong_at = heard.length > memory_limit ? @random.rand(heard.length) : nil
          heard.each_with_index do |event, index|
            tone = index == wrong_at ? event[:tone] % 5 + 1 : event[:tone]
            input({kind: :tone, value: tone}, at: after(180, 330))
            break if @trace.finished?
          end
        end
      end

      def hit_duck
        5.times do
          playback = stimulus
          input({kind: :playback_started, playback_id: playback[:id]}, at: after(30, 80))
          started = @now
          duration = playback[:events].map { |event| event[:offset_ms] + event[:duration_ms] }.max
          input({kind: :playback_finished, playback_id: playback[:id]}, at: started + duration)
          position = (playback[:events].first.fetch(:pan) * 4 + 5).round
          position = [[position + (@random.rand(2).zero? ? -1 : 1), 1].max, 9].min if @random.rand(100) < 20
          input({kind: :target, value: position}, at: started + 300 + @random.rand(700))
        end
      end

      def quiz
        question = view.fetch(:question)
        # No fabricated general knowledge and no reading correct_index from
        # the prepared question pack. This baseline picks a visible answer.
        value = @random.rand(question.fetch(:choices).length)
        input({kind: :answer, value: value}, at: after(2_500 + [question.fetch(:prompt).length * 12, 3_000].min, 6_000))
      end
    end
    private_constant :Planner
  end
end
