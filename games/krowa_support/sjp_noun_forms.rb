# encoding: UTF-8

module GameRoomKrowa
  # Classifies the forms actually listed by SJP for one entry. These are
  # inflection rules, not a separate word list. Unknown/irregular forms are
  # left unclassified so that the definition provider can use its fallback.
  #
  # Adapted from SJP.PL's polish.aff, 2026-09-01, under CC BY 4.0.
  # Source and attribution: THIRD_PARTY_NOTICES.md.
  module SjpNounForms
    NOUN_FLAGS = %w[A C D K L M N O P Q R S T U V W Z a f l m n o p q r s t u w z].freeze
    PLURAL_FLAGS = %w[A o q s t w z].freeze

    # flag | suffix condition | removed ending | added ending
    # M/L reuse the genitive-singular form only with regular plural inflection
    # and without a separate nominative plural class. U/V contribute -a
    # plurals; V/K/r/u contain mixed cases,
    # so matching a row alone would also accept oblique forms.
    RULE_DATA = <<~'SJP_NOUN_RULES'.dup.force_encoding(Encoding::UTF_8).freeze
      M|[^bcdfhijłmnprstvwxyzż]a|a|i
      M|[^k]ha|a|y
      M|[gk]ha|a|i
      M|ia|a|
      M|[chjnrstśz]ja|a|i
      M|[aeioóuy]ja|ja|i
      M|[^g]na|a|y
      M|[^a]gna|a|y
      M|[^s]agna|a|y
      M|sagna|a|i
      M|[aeou]ya|ya|i
      M|[^aeou]ya|a|i
      M|[bcdfłmprstvwxzż]a|a|y
      M|c||y
      M|[^eś]ć|ć|ci
      M|[^hł]eć|ć|ci
      M|[hł]eć|eć|ci
      M|[^e]ść|ć|ci
      M|[^z]eść|ć|ci
      M|ześć|eść|ci
      M|j|j|i
      M|[^eó]l||i
      M|[^i]el||i
      M|[^g]iel||i
      M|giel|iel|li
      M|ól|ól|oli
      M|[^e]ń|ń|ni
      M|[^d]eń|ń|ni
      M|deń|eń|ni
      M|p||i
      M|[^e]ś|ś|si
      M|[^i]eś|ś|si
      M|[^w]ieś|ś|si
      M|wieś|ieś|si
      M|[hnrt]ew|ew|wi
      M|[gk]iew|iew|wi
      M|[^s]z||y
      M|[^e]sz||y
      M|esz|esz|szy
      M|[^ądó]ź|ź|zi
      M|ąź|ąź|ęzi
      M|óź|óź|ozi
      M|[^ąó]dź|ź|zi
      M|ódź|ódź|odzi
      M|ądź|ądź|ędzi
      M|[^ąe]ż||y
      M|[^r]eż||y
      M|[^r]ąż|ąż|ęży
      M|rąż||y
      M|reż|eż|ży
      L|[^icnw]a|a|i
      L|ia|a|
      L|ś|ś|si
      U|o|o|a
      U|e|e|a
      V|um|um|a
      V|[^i]ę||ta
      V|mię|ę|ona
      V|[^m]ię||ta
      K|[^gk]a|a|e
      K|[gk]a|a|ie
      r|[^acgijkloyzżx]owie|owie|y
      r|[cjlyż]owie|owie|e
      r|[^cds]zowie|owie|y
      r|[cds]zowie|owie|e
      r|[kg]owie|owie|i
      r|iowie|owie|e
      u|[^ąó][bpw]||ie
      u|ów|ów|owie
      u|ąb|ąb|ębie
      u|ąp||ie
    SJP_NOUN_RULES

    RULES = RULE_DATA.lines.each_with_object({}) do |line, rules|
      flag, condition, removed, added = line.chomp.split("|", -1)
      (rules[flag] ||= []) << [Regexp.new("#{condition}\\z"), removed.freeze, added.freeze].freeze
    end.transform_values { |rules| rules.freeze }.freeze

    module_function

    def nominative?(word, lemma, forms, indeclinable: false)
      noun = forms.keys.any? { |flag| NOUN_FLAGS.include?(flag) }
      return noun || indeclinable if word == lemma
      return false unless noun

      return true if PLURAL_FLAGS.any? { |flag| forms.fetch(flag, []).include?(word) }

      separate_plural = (PLURAL_FLAGS + ["K"]).any? { |flag| forms.key?(flag) }
      RULES.any? do |flag, rules|
        next false if %w[M L].include?(flag) && (separate_plural || !forms.key?("N"))
        next false if flag == "U" && !forms.key?("V")
        next false unless forms.fetch(flag, []).include?(word)

        rules.any? do |condition, removed, added|
          next false unless condition.match?(lemma) && lemma.end_with?(removed)

          stem = removed.empty? ? lemma : lemma[0...-removed.length]
          stem + added == word
        end
      end
    end

    private_constant :NOUN_FLAGS, :PLURAL_FLAGS, :RULE_DATA, :RULES
  end
end
