# encoding: UTF-8
require 'base64'
module GameRoomTournamentMarker
  class Invalid < ArgumentError; end
  class SavingDisabled < ArgumentError; end
  module_function

  # This is a local restriction, not proof of tournament authority. Even an
  # incomplete marker must not turn a tournament table into a savable game.
  def present?(*records)
    records.any? do |record|
      record.is_a?(Hash) && %w[tournament_match __tournament_match match_ref tournament].any? { |key| record.key?(key) }
    end
  end

  def ensure_savable!(*records, tournament: nil)
    if present?(*records) || !tournament.nil?
      raise SavingDisabled, 'Tournament games cannot be saved or resumed from a saved game.'
    end
    true
  end

  # Compact only the discovery pointer; the native table and signed result
  # binding retain the explicit fields. The two hex digests occupy 64 bytes.
  def pack(value)
    value=copy(value)
    [value['publication_ref']['author'],value['publication_ref']['publication_key'],
      Base64.strict_encode64([value['schedule_id']+value['match_id']].pack('H*')),value['leg']]
  end

  def unpack(value)
    raise Invalid,'Invalid tournament discovery pointer' unless value.is_a?(Array) && value.size==4 && value[2].is_a?(String) && value[2].bytesize==88
    begin
      bytes=Base64.strict_decode64(value[2])
    rescue ArgumentError
      raise Invalid,'Invalid tournament discovery digests'
    end
    raise Invalid,'Invalid tournament discovery digests' unless bytes.bytesize==64
    digests=bytes.unpack1('H*')
    copy({'publication_ref'=>{'author'=>value[0],'publication_key'=>value[1]},
      'schedule_id'=>digests[0,64],'match_id'=>digests[64,64],'leg'=>value[3]})
  end

  # Discovery is only a pointer. Tournament code verifies this against the
  # authenticated binding before entry/start; no supplied table is authority.
  def copy(value)
    unless value.is_a?(Hash) && value.keys.sort==%w[leg match_id publication_ref schedule_id] &&
        value['leg'].is_a?(Integer) && value['leg'].positive? &&
        %w[match_id schedule_id].all?{|key|value[key].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value[key])}
      raise Invalid,'Invalid tournament table marker'
    end
    ref=value['publication_ref']
    unless ref.is_a?(Hash) && ref.keys.sort==%w[author publication_key] &&
        ref.values.all?{|item|item.is_a?(String) && item.bytesize.between?(1,128)}
      raise Invalid,'Invalid tournament reference'
    end
    {'publication_ref'=>ref.transform_values{|text|text.dup.freeze}.freeze,
      'schedule_id'=>value['schedule_id'].dup.freeze,'match_id'=>value['match_id'].dup.freeze,'leg'=>value['leg']}.freeze
  end
end
