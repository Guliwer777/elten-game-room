# frozen_string_literal: true

module GameRoomDuckRacing
  module RaceEffects
    private

    def perform_effect(seat, source, effect)
      kind, value, extra = effect
      racer = @state[:racers].fetch(seat)
      case kind
      when :move
        move(seat, value, effect: true)
      when :random_move
        distance = @state[:random].rand(extra - value + 1) + value
        distance = -distance if @state[:random].rand(2).zero?
        move(seat, distance, effect: true)
      when :feathers
        actual = [value, -racer[:feathers]].max
        racer[:feathers] += actual
        notice(:feathers, seat, actual) unless actual.zero?
      when :steal_feathers
        return if source == seat
        amount = [value, racer[:feathers]].min
        racer[:feathers] -= amount
        @state[:racers].fetch(source)[:feathers] += amount
        notice(:stole_feathers, source, seat, amount) if amount.positive?
      when :cards
        draw_cards(seat, value)
      when :everyone_cards
        @state[:racers].each_key { |receiver| draw_cards(receiver, value) }
      when :steal_cards
        return if source == seat
        value.times do
          break if racer[:hand].empty?
          card = racer[:hand].delete_at(@state[:random].rand(racer[:hand].length))
          @state[:racers].fetch(source)[:hand] << card
          notice(:stole_card, source, seat)
        end
      when :swap_hands
        other = @state[:racers].fetch(source)
        other[:hand], racer[:hand] = racer[:hand], other[:hand]
        other[:hand_epoch] += 1
        racer[:hand_epoch] += 1
        notice(:swapped_hands, source, seat)
      when :pass_hands
        racers = @state[:racers].values
        hands = racers.map { |recipient| recipient[:hand] }
        racers.each_with_index do |recipient, index|
          recipient[:hand] = hands.fetch((index - 1) % hands.length)
          recipient[:hand_epoch] += 1
        end
        notice(:passed_hands)
      when :skip
        racer[:skip_turns] += value
        notice(:skip_added, seat, value)
      when :die
        Dice.change!(racer, sides: value, rolls: extra)
        notice(:die_changed, seat, value, extra)
      when :quiz
        start_challenge(@state[:racers].keys,
          trigger: source.nil? ? :square_question : :question_card, kind: "quiz", initiator: source || seat)
      when :duel
        start_challenge([source, seat], trigger: :challenge_card, initiator: source)
      when :group_challenge
        start_challenge(@state[:racers].keys, trigger: :group_card, initiator: source)
      else
        raise ArgumentError, "Unknown Duck Racing effect: #{kind}"
      end
    end

    def draw_cards(seat, count)
      draw = Cards.draw(count: count, next_serial: @state[:next_card], random: @state[:random])
      @state[:next_card] = draw.next_serial
      @state[:racers].fetch(seat)[:hand].concat(draw.cards)
      notice(:drew_cards, seat, count)
    end
  end
end
