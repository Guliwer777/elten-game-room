# encoding: UTF-8
# frozen_string_literal: true
require 'json'

module GameRoomTournaments
  # Nie zakładamy wersji JSON hosta. Nowszy parser deduplikuje przed []=;
  # starszy może ignorować allow_duplicate_key. Dopuszczamy tylko rzeczywiście
  # sprawdzoną kombinację obu zabezpieczeń, bez powtórnego liberalnego parsowania.
  module StrictJson
    class IncompatibleRuntime < StandardError; end

    class UniqueObject < Hash
      def []=(key, value)
        raise JSON::ParserError, 'duplicate JSON key' if key?(key)
        super
      end
    end
    private_constant :UniqueObject

    PROBES = ['{"key":1,"key":1}', '{"key":0,"key":1}',
      '{"key":1,"\\u006bey":1}', '{"a":[{"b":{"key":null,"key":1}}]}'].freeze
    private_constant :PROBES
    module_function

    def verify!
      unless decode('{"key":1}', 8) == { 'key' => 1 }
        raise IncompatibleRuntime, 'invalid JSON parser result'
      end
      PROBES.each do |source|
        begin
          decode(source, 8)
        rescue JSON::ParserError
          next
        end
        raise IncompatibleRuntime, 'JSON parser accepts duplicate keys'
      end
      true
    end

    def parse(source, max_nesting:)
      verify!
      plain(decode(source, max_nesting))
    end

    # Strażnik jest tylko dla parsera; wynik musi pozostawać zwykłym JSON-em.
    def plain(value)
      case value
      when Hash then value.to_h { |key, child| [key, plain(child)] }
      when Array then value.map { |child| plain(child) }
      else value
      end
    end
    private_class_method :plain

    def decode(source, max_nesting)
      JSON.parse(source, create_additions: false, allow_duplicate_key: false,
        object_class: UniqueObject, max_nesting: max_nesting)
    end
    private_class_method :decode
  end
end
