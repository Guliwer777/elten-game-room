# frozen_string_literal: true

require 'weakref'
require_relative '../host_bridge'

module GameRoomDuckRacing
  # The native snapshot has one flag per key, losing both order and a second
  # short tap in the same frame. Observe its existing event batch, without
  # consuming it or changing any host flags. Only the active challenge field
  # and its explicitly declared keys are recorded; there is no global key log.
  module Keyboard
    MARKER = :@game_room_duck_keyboard_bridge
    FRAME = :@game_room_duck_keyboard_frame
    MODIFIERS = {shift: [0x10, 0xA0, 0xA1], control: [0x11, 0xA2, 0xA3],
      alt: [0x12, 0xA4, 0xA5], command: [0x5B, 0x5C], insert: [0x2D]}.freeze
    Frame = Struct.new(:target_id, :generation, :presses, :held, keyword_init: true)
    module_function

    def install
      return unless defined?(EltenAPI::KeyboardState)

      target = EltenAPI::KeyboardState.singleton_class
      bridge = GameRoomHostBridge.locate(target, marker: MARKER,
        method_name: :update, source: '/lib/duck_racing/keyboard.rb')
      return if bridge && bridge.instance_variable_get(:@observer).equal?(self)

      @active = nil
      @suppressed = {}
      bridge ||= GameRoomHostBridge.prepare(target, marker: MARKER)
      observer = self
      bridge.module_eval do
        define_method(:update) do |*arguments, **options, &block|
          field = observer.active_field
          return super(*arguments, **options, &block) unless field

          previous = current.held.dup
          result = super(*arguments, **options, &block)
          observer.capture(field, result, options, previous)
          result
        end
        define_method(:suppress_held_until_release) do |*arguments, **options, &block|
          observer.suppress(current.held)
          super(*arguments, **options, &block)
        end
        define_method(:reset) do |*arguments, **options, &block|
          observer.reset
          super(*arguments, **options, &block)
        end
      end
      bridge.instance_variable_set(:@observer, observer)
    end

    def active_field
      @active.__getobj__ if @active && @active.weakref_alive?
    end

    def activate(field)
      install
      return if active_field.equal?(field)

      @active = WeakRef.new(field)
      @suppressed = {}
      clear(field)
    end

    def deactivate(field)
      return unless active_field.equal?(field)

      @active = nil
      @suppressed = {}
    end

    def clear(field)
      return unless defined?(EltenAPI::KeyboardState)

      @generation = @generation.to_i + 1
      suppress(EltenAPI::KeyboardState.current.held) if active_field.equal?(field)
    end

    def suppress(held)
      field = active_field
      return unless field

      @suppressed ||= {}
      field.duck_keys.each { |key| @suppressed[key] = true if held[key] }
    end

    def reset
      @suppressed = {}
      @generation = @generation.to_i + 1
    end

    def capture(field, result, options, previous)
      return if result.frozen? || options[:active] == false || !result.equal?(EltenAPI::KeyboardState.current)
      return unless options[:events].is_a?(Array) && active_field.equal?(field)

      keys = field.duck_keys
      down = previous.dup
      blocked = (@suppressed || {}).dup
      presses, mentioned = [], []
      options[:events].each do |code, state, press_state|
        code = code.to_i
        fresh = !down[code]
        down[code] = [true, :repeat, :held].include?(state)
        next unless keys.include?(code)

        mentioned << code
        if state == false
          blocked.delete(code)
        elsif state == true && fresh && !blocked[code]
          modifiers = press_state ? raw_modifiers(press_state) : modifiers(down)
          presses << [code, modifiers.freeze].freeze
        end
      end
      # Flags/synthetic input has no ordering. Accept only an unambiguous
      # single fresh edge; never invent a multi-key sequence from key codes.
      missing = keys.select { |key| result.first_pressed[key] && !blocked[key] && !mentioned.include?(key) }
      if presses.empty? && missing.length == 1
        code = missing.first
        presses << [code, modifiers(result.press_states[code] || result.held).freeze].freeze
      end
      raw = options[:raw_state].to_s
      @suppressed = blocked.select { |key, _| (raw.getbyte(key).to_i & 0x80) != 0 }
      result.instance_variable_set(FRAME, Frame.new(target_id: field.object_id,
        generation: @generation, presses: presses.freeze, held: result.held.dup.freeze).freeze)
    end

    def raw_modifiers(state)
      raw = state.to_s
      MODIFIERS.keys.select { |name| MODIFIERS[name].any? { |key| (raw.getbyte(key).to_i & 0x80) != 0 } }
    end

    def modifiers(state)
      MODIFIERS.keys.select { |name| MODIFIERS[name].any? { |key| state[key] } }
    end

    def frame(field)
      return unless defined?(EltenAPI::KeyboardState) && active_field.equal?(field)

      frame = EltenAPI::KeyboardState.current.instance_variable_get(FRAME)
      frame if frame.is_a?(Frame) && frame.target_id == field.object_id && frame.generation == @generation
    end
  end
end
