# frozen_string_literal: true
require_relative 'hand'

module GameRoomMahjong
  class ClaimWindow
    Resolution = Struct.new(:type, :seat, :first_kind, keyword_init: true)
    attr_reader :seats, :discarder, :tile_kind, :generation, :offers, :responses

    def initialize(seats:, discarder:, tile_kind:, generation:, offers:, responses: {})
      unless seats.is_a?(Integer) && [3, 4].include?(seats) && discarder.is_a?(Integer) && discarder.between?(0, seats - 1) &&
          generation.is_a?(Integer) && generation.between?(0, (1 << 63) - 1) && offers.is_a?(Hash) && responses.is_a?(Hash)
        raise ArgumentError, 'Invalid mahjong claim window'
      end
      Tiles.validate_kind(tile_kind, bonuses: false)
      @seats, @discarder, @tile_kind, @generation = seats, discarder, tile_kind, generation
      peers = (0...seats).to_a - [discarder]
      raise ArgumentError, 'Claims must describe every other seat' unless offers.keys.sort == peers
      @offers = offers.to_h do |seat, choices|
        raise ArgumentError, 'Invalid claim options' unless choices.is_a?(Array)
        checked = choices.map { |choice| validate_choice(choice, seat).dup.freeze }
        checked << [:pass].freeze unless checked.include?([:pass])
        [seat, checked.uniq.freeze]
      end.freeze
      unless (responses.keys - peers).empty? && responses.all? { |seat, choice| @offers.fetch(seat).include?(choice) }
        raise ArgumentError, 'Invalid claim response'
      end
      @responses = responses.transform_values { |choice| choice.dup.freeze }.freeze
      freeze
    end

    def respond(seat:, choice:, generation:)
      raise ArgumentError, 'Stale mahjong claim' unless generation.is_a?(Integer) && generation == @generation
      raise ArgumentError, 'Illegal mahjong claim' unless offers.key?(seat) && offers.fetch(seat).include?(choice)
      if responses.key?(seat)
        raise ArgumentError, 'The seat already responded to this discard' unless responses[seat] == choice
        return self
      end
      self.class.new(seats: seats, discarder: discarder, tile_kind: tile_kind,
        generation: generation, offers: offers, responses: responses.merge(seat => choice))
    end

    def pending
      offers.keys - responses.keys
    end

    # Never commit a chow while somebody can still win or call pung/kong.
    # Head-bump follows seat order after the discard, not arrival time.
    def resolution
      return nil unless pending.empty?
      claims = responses.reject { |_seat, choice| choice.first == :pass }
      return Resolution.new(type: :passed).freeze if claims.empty?
      priority = {win: 0, pung: 1, kong: 1, chow: 2}
      seat, choice = claims.min_by { |player, offer| [priority.fetch(offer.first), (player - discarder) % seats] }
      Resolution.new(type: choice.first, seat: seat, first_kind: choice[1]).freeze
    end

    private

    def validate_choice(choice, seat)
      raise ArgumentError, 'Malformed mahjong claim' unless choice.is_a?(Array)
      case choice.first
      when :pass, :win
        raise ArgumentError, 'Unexpected claim arguments' unless choice.length == 1
      when :pung, :kong
        raise ArgumentError, 'Claimed set must match the discarded tile' unless choice.length == 2 && choice[1].is_a?(Integer) && choice[1] == tile_kind
      when :chow
        unless choice.length == 2 && seat == (discarder + 1) % seats && seats == 4 && Hand.tiles_for(choice).include?(tile_kind)
          raise ArgumentError, 'Only the next player may chow in a four-seat game'
        end
      else raise ArgumentError, 'Unknown mahjong claim'
      end
      choice
    end
  end
end
