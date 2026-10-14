# encoding: UTF-8
require_relative 'readiness_contract'

module GameRoomTournaments
  # DTO jest opisem zamiaru, nigdy dowodem zatwierdzenia planu.
  class ReadinessRequest
    C = ReadinessContract
    def self.build(raw)
      value = C.copy(raw.is_a?(self) ? raw.to_h : raw)
      C.fields!(value, %w[version scope match_ref availability expected_ready_revision policy_ref])
      C.target!(value['scope'], value['match_ref'])
      raise C::Invalid, :invalid_version unless value['version'].eql?(1)
      raise C::Blocked, :later_unsupported if value['availability']=='later'
      raise C::Invalid, :invalid_availability unless %w[ready withdrawn].include?(value['availability'])
      raise C::Invalid, :invalid_revision unless C::Data.integer?(value['expected_ready_revision'])
      C.text!(value['policy_ref'])
      new(C.frozen_copy(value))
    end

    def initialize(data)
      @data = data
      freeze
    end
    private_class_method :new

    def to_h
      @data
    end
  end
end
