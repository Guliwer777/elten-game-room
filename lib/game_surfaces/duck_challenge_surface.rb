# frozen_string_literal: true

require_relative 'specifications'
require_relative 'question_surface'
require_relative '../duck_racing/keyboard'
require_relative '../../games/duck_racing_support/challenge_presentation'

module GameSurfaces
  # Native controls keep their accessibility/editing behaviours. Only their
  # game commands are handled here, using ordered physical edges instead of
  # native repeat/selection callbacks. There is no timer or game model.
  module DuckChallengeField
    attr_reader :duck_surface

    def attach_duck_surface(surface)
      @duck_surface = surface
      @duck_down, @duck_blocked = [], []
      self
    end

    def duck_keys
      @duck_surface.keys
    end

    def get_tips
      # This native control survives accepted phase changes. Keep its current
      # instruction separate from the host's custom and built-in help tips.
      inherited = super.to_a
      instruction = @duck_surface&.presentation&.[](:instruction).to_s
      instruction.empty? ? inherited : [instruction] + inherited
    end

    def update
      GameRoomDuckRacing::Keyboard.activate(self)
      key_pressed?(duck_keys.first) # refresh the host's snapshot first
      frame = GameRoomDuckRacing::Keyboard.frame(self)
      presses = if frame
        frame.equal?(@duck_last_frame) ? [] : frame.presses
      elsif respond_to?(:keyboard_modifier_held_when_pressed?, true) && defined?(EltenAPI::KeyboardState)
        []
      else
        fallback_presses
      end
      # Capture fresh edges first, then let the owning client open input if
      # its countdown ended. Held pre-cue keys are not fresh edges; the same
      # frame's new characters must reach an already writable native edit.
      @duck_surface.before_input&.call
      @duck_native_update = true
      super
      @duck_native_update = false
      @duck_last_frame = frame
      @duck_surface.control_updated
      presses.each { |code, modifiers| @duck_surface.key_edge(code, modifiers) }
    ensure
      @duck_native_update = false
    end

    def key_pressed?(key, **options)
      return false if @duck_native_update && @duck_surface.native_command?(key)

      super
    end

    def key_processed(key)
      return true if @duck_surface.native_command?(key)

      super
    end

    def focus(*arguments, **options)
      unless @duck_native_update
        GameRoomDuckRacing::Keyboard.activate(self)
        clear_duck_input
      end
      super
    end

    def blur
      @duck_surface.clear_pending
      GameRoomDuckRacing::Keyboard.deactivate(self)
      super if defined?(super)
    end

    def clear_duck_input
      @duck_surface.clear_pending
      GameRoomDuckRacing::Keyboard.clear(self)
      @duck_blocked = duck_keys.select { |key| key_held?(key) }
      @duck_down = @duck_blocked.dup
      @duck_last_frame = GameRoomDuckRacing::Keyboard.frame(self)
    end

    private

    def fallback_presses
      down = duck_keys.select { |key| key_held?(key) }
      @duck_blocked &= down
      fresh = duck_keys.select { |key| key_pressed?(key) && !@duck_down.include?(key) && !@duck_blocked.include?(key) }
      @duck_down = down
      return [] unless fresh.length == 1

      code = fresh.first
      modifiers = GameRoomDuckRacing::Keyboard::MODIFIERS.keys.select do |name|
        if respond_to?(:keyboard_modifier_held_when_pressed?, true) && name != :insert
          keyboard_modifier_held_when_pressed?(code, name == :alt ? :option : name)
        else
          GameRoomDuckRacing::Keyboard::MODIFIERS[name].any? { |key| key_held?(key) }
        end
      end
      [[code, modifiers]]
    end
  end

  class DuckChallengeButton < Button
    include DuckChallengeField

    def suppress_next_focus!
      @duck_suppress_next_focus = true
    end

    def clear_suppressed_focus!
      @duck_suppress_next_focus = false
    end

    def focus(*arguments, **options)
      # Native Button has no spk argument. Keep its focus/input and Braille
      # behaviour; silence only this control's speech for this one focus.
      @duck_quiet_focus, @duck_suppress_next_focus = @duck_suppress_next_focus, false
      super
    ensure
      @duck_quiet_focus = false
    end

    private

    def speak(*arguments, **options, &block)
      super unless @duck_quiet_focus
    end
  end

  class DuckChallengeList < RefreshAwareListBox
    include DuckChallengeField

    def game_shortcut_keys=(keys)
      # Table shortcut rebinding must not turn ball commands back into the
      # native list's character search, even while another player is choosing.
      reserved = @duck_surface&.spec&.kind == 'numbered_balls' ? ('0'..'9').to_a : []
      super(keys.to_a + reserved)
    end
  end

  class DuckChallengeEdit < RefreshAwareEditBox
    include DuckChallengeField

    def game_shortcut_signatures=(signatures)
      super
      @numeric_shortcuts = signatures.filter_map do |key, modifiers|
        key.to_s.downcase if modifiers.to_a.empty? && key.to_s.match?(/\A[a-z]\z/i)
      end
    end

    def game_shortcut_in_text?(key, modifiers)
      return false unless @duck_surface&.presentation&.[](:auto_submit_length) &&
        modifiers.empty? && @numeric_shortcuts.to_a.include?(key)

      # A quick Ctrl+C may already be released when Form dispatches C.
      # Keep the modifiers captured at the letter's press, not just those
      # still held at the end of this UI frame.
      ![:shift, :control, :option, :command].any? do |modifier|
        keyboard_modifier_held_when_pressed?(key.upcase.ord, modifier)
      end
    end

    def key_processed(key)
      modifiers = []
      modifiers << :shift if key_held?(:shift)
      modifiers << :control if key_held?(:control)
      modifiers << :alt if key_held?(:alt)
      return false if game_shortcut_in_text?(key.to_s.sub(/\Akey_/, '').downcase, modifiers)

      super
    end
  end

  class DuckChallengeSurface
    include ActionEmitter
    using GameRoomLocalization::Translations
    attr_reader :spec, :presentation
    attr_accessor :before_input

    ENTER, SPACE, F5 = 0x0D, 0x20, 0x74
    SYMBOLS = {enter: ENTER, space: SPACE}.freeze
    DIGITS = (0..9).to_h { |digit| [0x30 + digit, digit] }.freeze

    def initialize(spec, state: {})
      raise ArgumentError, 'A challenge needs an identity' if spec.challenge_id.to_s.empty?

      @spec, @pending, @press_id = spec, [], state_value(state, 'press_id', 0).to_i
      @presentation = projection(spec.view)
      state = {} unless state_value(state, 'challenge_id', spec.challenge_id) == spec.challenge_id
      @field = build_field(state).attach_duck_surface(self)
      if @presentation[:auto_submit_length]
        # Native edits (including paste) emit :change; set_text used to restore
        # a draft does not. Defer until the complete native editing batch.
        @field.on(:change) { @number_edited = true }
        @number_submitted_generation = @field.game_room_edit_generation if state_value(state, 'number_submitted', false)
      end
      @field.game_shortcut_keys = ('0'..'9').to_a if @field.respond_to?(:game_shortcut_keys=)
      refresh_control
    end

    def fields
      [@field]
    end

    def state
      result = {'challenge_id' => @spec.challenge_id, 'press_id' => @press_id}
      if @presentation[:mode] == :text
        result.merge!('text' => @field.text.to_s, 'index' => @field.index, 'check' => @field.check)
        if @presentation[:auto_submit_length]
          result['number_submitted'] = @number_submitted_generation == @field.game_room_edit_generation
        end
      elsif @presentation[:mode] == :list
        result['index'] = @field.index
      end
      result
    end

    def reusable_for?(spec)
      # Keep a pending native edit across unrelated accepted updates, but a
      # role change may replace the answer edit with an observation control.
      spec.is_a?(DuckChallengeSpec) && spec.challenge_id == @spec.challenge_id &&
        spec.kind == @spec.kind && spec.viewer == @spec.viewer &&
        projection(spec.view)[:mode] == @presentation[:mode]
    end

    def update_spec(spec)
      raise ArgumentError, 'A different challenge needs a new surface' unless reusable_for?(spec)

      @spec = spec
      present(spec.view)
    end

    def present(view)
      updated = projection(view)
      changed_phase = updated[:boundary] != @presentation[:boundary]
      @presentation = updated
      if changed_phase
        @swap_position = nil
        clear_input
      end
      refresh_control
      self
    end

    def keys
      if @presentation[:practice]
        return [ENTER, SPACE] + case @spec.kind
        when 'simon' then (0x31..0x35).to_a
        when 'hit_duck' then (0x31..0x39).to_a
        when 'rhythm' then [0x46, 0x4A]
        when 'audio_ball' then [0x26, 0x57, 0x25, 0x44, 0x28, 0x53]
        when 'sound_memory', 'axel_pong' then []
        end
      end
      case @spec.kind
      when 'rock_paper_scissors', 'risky_dice' then [ENTER]
      when 'blackjack' then [SPACE, ENTER]
      when 'numbered_balls' then [0x31, 0x32, 0x33]
      when 'quiz' then [ENTER, 0x31, 0x32, 0x33, 0x34]
      when 'sound_order' then (0x31..0x38).to_a
      when 'simon' then (0x31..0x35).to_a
      when 'sound_memory' then DIGITS.keys
      when 'hit_duck' then (0x31..0x39).to_a
      when 'rhythm' then [ENTER, F5, 0x46, 0x4A]
      when 'count_ducks' then [ENTER, F5]
      else [ENTER]
      end
    end

    def native_command?(key)
      code = key.is_a?(Integer) ? key : SYMBOLS[key.to_s.sub(/\Akey_/, '').to_sym]
      code && keys.include?(code)
    end

    def key_edge(code, modifiers)
      return if modifiers.any? { |modifier| modifier != :shift }
      return if modifiers.include?(:shift) && @spec.kind != 'sound_order'

      return unless @presentation[:enabled]
      return if @presentation[:auto_submit_length] && code == ENTER && number_submitted?
      return unless action_allowed?

      if @presentation[:practice]
        action = [ENTER, SPACE].include?(code) ? {kind: :ready} : {kind: :preview, value: code}
        queue_input(action) if keys.include?(code)
        return
      end

      digit = DIGITS[code]
      action = case @spec.kind
      when 'rock_paper_scissors'
        {kind: :choose, value: %w[rock paper scissors][@field.index]} if code == ENTER
      when 'dice_duel'
        {kind: :roll} if code == ENTER
      when 'blackjack'
        code == SPACE ? {kind: :hit} : code == ENTER ? {kind: :stand} : nil
      when 'risky_dice'
        {kind: @field.index.zero? ? :roll : :save} if code == ENTER
      when 'numbered_balls'
        {kind: :take, value: digit} if digit && digit.between?(1, 3)
      when 'quiz'
        index = if digit && digit.between?(1, 4)
          digit - 1
        elsif code == ENTER
          @question_surface.submission_action&.payload&.fetch('answer')
        end
        {kind: :answer, value: index} unless index.nil?
      when 'sound_order'
        if digit && modifiers.include?(:shift)
          swap_action(digit)
        elsif digit
          {kind: :preview, value: digit}
        end
      when 'simon'
        {kind: :tone, value: digit} if digit && @presentation[:phase] == :responding
      when 'sound_memory'
        {kind: :reveal, value: digit} unless digit.nil?
      when 'hit_duck'
        {kind: :target, value: digit} if digit && @presentation[:phase] == :responding
      when 'rhythm'
        rhythm_action(code)
      when 'count_ducks'
        if @presentation[:phase] == :responding
          code == F5 ? (@presentation[:playback_id].nil? ? {kind: :replay} : nil) : answer_action(code, numeric: true)
        end
      else
        answer_action(code, numeric: false)
      end
      queue_input(action)
    end

    def control_updated
      return unless @presentation[:auto_submit_length] && @number_edited

      @number_edited = false
      value = @field.text.to_s
      return unless value.length == @presentation[:auto_submit_length] && value.match?(/\A[0-9]+\z/)
      return if @spec.kind == 'count_ducks' && @presentation[:phase] != :responding
      return unless @presentation[:enabled] && !number_submitted? && action_allowed?

      queue_input(answer_action(ENTER, numeric: @spec.kind == 'count_ducks'))
    end

    def input_selected?(form)
      return false if form.respond_to?(:game_room_background_help?) && form.game_room_background_help?

      form.fields[form.index].equal?(@field)
    end

    def input_active?(form)
      active = input_selected?(form)
      active &&= $activecontrols.include?(@field) if defined?($activecontrols) && $activecontrols.is_a?(Array)
      active
    end

    def take_input(form)
      pending, @pending = @pending, []
      number_generation, @number_queued_generation = @number_queued_generation, nil
      return [] if pending.empty?

      return [] unless input_active?(form) && @presentation[:enabled] && action_allowed?

      @number_submitted_generation = number_generation unless number_generation.nil?
      pending
    end

    def clear_pending
      @pending.clear
      @number_queued_generation = nil
      @number_edited = false
    end

    def clear_input
      @field.clear_duck_input
    end

    def activate_input
      GameRoomDuckRacing::Keyboard.activate(@field)
    end

    def deactivate_input
      clear_pending
      GameRoomDuckRacing::Keyboard.deactivate(@field)
    end

    private

    def projection(view)
      GameRoomDuckRacing::ChallengePresentation.project(kind: @spec.kind, view: view, viewer: @spec.viewer)
    end

    def build_field(state)
      case @presentation[:mode]
      when :text
        value = GameRoomContent.utf8(state_value(state, 'text', '').to_s)
        flags = @presentation[:auto_submit_length] ? EditBox::Flags::Numbers : 0
        field = DuckChallengeEdit.new(@presentation[:header], text: value, type: flags,
          quiet: true, max_length: @presentation[:max_length])
        field.restore_selection(index: state_value(state, 'index', value.length), check: state_value(state, 'check', value.length))
        field
      when :list
        return build_quiz_field(state) if @spec.kind == 'quiz'

        DuckChallengeList.new(@presentation[:options], header: @presentation[:header], quiet: true,
          index: state_value(state, 'index', 0).to_i)
      else
        DuckChallengeButton.new(@presentation[:header])
      end
    end

    def build_quiz_field(state)
      # The regular Quiz owns this layout, including its non-answer question
      # row. Only submitting is routed through the challenge's private trace.
      question = QuestionSpec.new(id: @spec.challenge_id,
        prompt: GameRoomDuckRacing::ChallengePresentation.prompt('quiz', @spec.view),
        mode: :single_choice, required: true, prompt_in_choices: true,
        show_submit_button: false,
        options: @presentation[:options].each_with_index.map do |label, index|
          QuestionOption.new(id: index.to_s, label: label, value: index)
        end)
      @question_surface = QuestionSurface.new(question, state: state)
      @question_surface.fields.first.extend(DuckChallengeField)
    end

    def refresh_control
      # A quiz question and its choices do not change within a challenge.
      # Keep the standard QuestionSurface header, cursor and option layout.
      return if @question_surface

      if @presentation[:mode] == :button
        @field.label = @presentation[:header]
      else
        @field.header = @presentation[:header]
      end
      if @presentation[:mode] == :text
        @field.flags = if @presentation[:preparing]
          @field.flags.to_i | EditBox::Flags::ReadOnly
        else
          @field.flags.to_i & ~EditBox::Flags::ReadOnly
        end
      end
      return unless @presentation[:mode] == :list

      options, keys = @presentation.values_at(:options, :option_keys)
      unless @last_options == [options, keys]
        @field.update_options(options, keys: keys)
        @last_options = [options, keys]
      end
    end

    def answer_action(code, numeric:)
      return unless code == ENTER
      return if @presentation[:auto_submit_length] && number_submitted?

      value = GameRoomContent.utf8(@field.text.to_s).strip
      return if value.empty?
      if numeric
        return unless value.match?(/\A[0-9]{1,9}\z/)
        value = value.to_i
      end
      @field.restore_selection(index: 0, check: @field.text.length)
      {kind: :answer, value: value}
    end

    def number_submitted?
      generation = @field.game_room_edit_generation
      generation == @number_queued_generation || generation == @number_submitted_generation
    end

    def queue_input(action)
      return unless action

      @press_id += 1
      @pending << action.merge(press_id: @press_id)
      if @presentation[:auto_submit_length] && action[:kind] == :answer
        @number_queued_generation = @field.game_room_edit_generation
      end
    end

    def rhythm_action(code)
      if @presentation[:phase] == :ready && @presentation[:playback_id].nil?
        return {kind: :begin} if code == ENTER
        return {kind: :replay} if code == F5 && @presentation[:replays_left] == 1
      elsif @presentation[:phase] == :responding && [0x46, 0x4A].include?(code)
        return {kind: :tone, value: code == 0x46 ? 'f' : 'j'}
      end
      nil
    end

    def swap_action(position)
      if @swap_position.nil? || @swap_position == position
        @swap_position = position
        return nil
      end
      action = {kind: :swap, value: @swap_position, other: position}
      @swap_position = nil
      action
    end
  end
end
