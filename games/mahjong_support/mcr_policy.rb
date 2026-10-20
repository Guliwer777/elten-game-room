# frozen_string_literal: true
require_relative 'mcr_kong_scoring'

module GameRoomMahjong
  # WMO English rulebook (2006 edition distributed in Mahjong_Rule_2013.pdf),
  # with the EMA September 2012 kong interpretation. These rules intentionally
  # retain this edition's allowed All Green/flush and All Terminals/Double
  # Pung combinations. Do not silently replace them with another platform's
  # scoring convention. Certification against all 81 patterns is still pending.
  module MCRPolicy
    GLOBAL = {
      1=>[9, 38, 49, 60, 61, 73], 2=>[10, 54, 59],
      4=>[22, 62, 73, 76], 5=>[17, 48, 49, 57, 67, 74, 79],
      6=>[19, 22, 62, 76, 79], 7=>[18, 52, 62, 79],
      8=>[18, 49, 55, 73, 76], 9=>[38, 73], 10=>[54, 59],
      11=>[18, 49, 55, 73], 12=>[33, 49, 62, 66],
      13=>[19, 22, 63, 69, 72, 76], 14=>[23, 64, 69],
      15=>[24, 49], 16=>[30, 71], 17=>[48, 57, 67, 74],
      18=>[49, 55, 73], 19=>[62, 79], 20=>[34, 52, 62],
      21=>[49, 68, 76], 22=>[76], 23=>[69],
      25=>[36, 76], 26=>[68, 76], 27=>[37, 76],
      29=>[63, 69, 70, 72, 76], 31=>[68, 76], 33=>[66],
      34=>[52, 62], 36=>[76], 37=>[76], 40=>[75],
      44=>[80], 46=>[80], 47=>[58], 48=>[57, 66, 67, 74],
      53=>[62, 79], 54=>[59], 56=>[62, 80], 57=>[67, 74],
      63=>[76], 68=>[76]
    }.transform_values(&:freeze).freeze
    SCOPED = {38=>[73]}.transform_values(&:freeze).freeze
    module_function

    def select(candidates)
      MCRCombination.select(candidates, exclusions: GLOBAL, scoped_exclusions: SCOPED)
    end
  end
end
