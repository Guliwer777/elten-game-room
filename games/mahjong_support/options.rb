# frozen_string_literal: true
require_relative '../base'
require_relative 'rules'

module GameRoomGames
  using GameRoomLocalization::Translations

  # One configuration form for the future single catalog entry. Only settings
  # implemented by the corresponding adapter are exposed.
  module MahjongOptions
    TABLE_VARIANTS = %w[hong_kong riichi mcr].freeze
    LENGTH_KEYS = {'hong_kong'=>'hong_kong_winds', 'riichi'=>'riichi_winds', 'mcr'=>'mcr_winds'}.freeze

    def option_definitions
      [
        OptionDefinition.new(key: 'variant', label: _('Mahjong variant'), kind: :choice, default: 'solitaire', choices: [
          OptionChoice.new(value: 'solitaire', label: _('Mahjong Solitaire')),
          OptionChoice.new(value: 'hong_kong', label: _('Hong Kong Old Style')),
          OptionChoice.new(value: 'riichi', label: _('Riichi')),
          OptionChoice.new(value: 'mcr', label: _('Mahjong Competition Rules (MCR)'))]),
        OptionDefinition.new(key: 'layout', label: _('Solitaire layout'), kind: :choice, default: 'terraces',
          choices: [OptionChoice.new(value: 'terraces', label: _('Terraces')),
            OptionChoice.new(value: 'flat', label: _('Flat layout'))], visible_if: {'variant'=>'solitaire'}),
        OptionDefinition.new(key: 'riichi_seats', label: _('Occupied seats, including bots'), kind: :choice, default: '4',
          choices: [OptionChoice.new(value: '4', label: _('Four players')),
            OptionChoice.new(value: '3', label: _('Three players (sanma)'))], visible_if: {'variant'=>'riichi'}),
        OptionDefinition.new(key: 'fan_progress', label: _('Basic scoring preview under W'), kind: :choice, default: 'yes',
          choices: [OptionChoice.new(value: 'yes', label: _('Yes')), OptionChoice.new(value: 'no', label: _('No'))],
          visible_if: {'variant'=>TABLE_VARIANTS}),
        mahjong_length_option('hong_kong', '4', %w[0 1 4]),
        mahjong_length_option('riichi', '2', %w[0 1 2]),
        mahjong_length_option('mcr', '4', %w[0 4])
      ]
    end

    def effective_option_definitions(selected = {})
      super.map do |definition|
        next definition unless definition.key.to_s == 'bot_delay'
        definition.dup.tap { |copy| copy.visible_if = {'variant'=>TABLE_VARIANTS} }
      end
    end

    def normalize_options(values)
      result = super
      variant = result.fetch('variant')
      # Ignore options from inactive variants, including old derived values
      # supplied by a saved preference. Replay uses only this selected profile.
      result.delete('fan_progress') if variant == 'solitaire'
      result.delete('layout') unless variant == 'solitaire'
      result.delete('riichi_seats') unless variant == 'riichi'
      LENGTH_KEYS.each { |profile, key| result.delete(key) unless profile == variant }
      if variant == 'solitaire'
        result['bot_delay'] = 0 if result.key?('bot_delay')
        result['seats'], result['match_winds'] = 1, 0
      else
        result['seats'] = variant == 'riichi' ? result.fetch('riichi_seats').to_i : 4
        result['match_winds'] = result.fetch(LENGTH_KEYS.fetch(variant)).to_i
      end
      result
    end

    def session_history_capacity(options)
      normalize_options(options)['variant'] == 'solitaire' ? nil : 32_768
    end

    def notification_option_keys(options)
      options['variant'] == 'riichi' ? %w[variant riichi_seats] : ['variant']
    end

    def maximum_players_for_options(options)
      normalize_options(options).fetch('seats')
    end

    def supports_bots_for_options?(options)
      normalize_options(options).fetch('variant') != 'solitaire'
    end

    def options_error(options, player_count: nil)
      values = normalize_options(options)
      return nil if player_count.nil? || player_count == values['seats']
      _('This Mahjong variant requires %{count} occupied seats, including bots.') % {count: values['seats']}
    end

    private

    def mahjong_length_option(variant, default, lengths)
      labels = {'0'=>_('One hand'), '1'=>_('East round'), '2'=>_('East and South rounds'), '4'=>_('Four wind rounds')}
      label = {'hong_kong'=>_('Hong Kong match length'), 'riichi'=>_('Riichi match length'), 'mcr'=>_('MCR match length')}.fetch(variant)
      OptionDefinition.new(key: LENGTH_KEYS.fetch(variant), label: label, kind: :choice,
        default: default, choices: lengths.map { |value| OptionChoice.new(value: value, label: labels.fetch(value)) },
        visible_if: {'variant'=>variant})
    end
  end
end
