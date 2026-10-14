# encoding: UTF-8
require 'json'
require 'digest'
require 'base64'
require_relative 'publication'
require_relative 'strict_json'

module GameRoomTournaments
  # Transport of a candidate document only. This is not a coordination seal,
  # roster lock, invitation permission or evidence of an accepted game result.
  module ServerPlanDocument
    Invalid = Publication::Invalid
    MAX_BYTES = 262_144
    PART_BYTES = 1536
    MAX_PARTS = (MAX_BYTES.to_f / PART_BYTES).ceil
    FIELDS = %w[operation_key tournament_id publication_digest roster_generation document_digest part_count part_index payload].freeze
    module_function

    def digest!(value)
      raise Invalid, :invalid_plan_digest unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def anchor!(anchor)
      unless anchor.is_a?(Hash) && anchor.keys.sort == %w[operation_key publication_digest roster_generation tournament_id].sort &&
          anchor['tournament_id'].is_a?(Integer) && anchor['tournament_id'] > 0
        raise Invalid, :invalid_plan_anchor
      end
      %w[operation_key publication_digest roster_generation].each { |key| digest!(anchor[key]) }
    end

    def encode(document, anchor:)
      anchor!(anchor)
      copy = copy_document(document)
      bytes = JSON.generate(copy).encode(Encoding::UTF_8)
      raise Invalid, :plan_document_limit if bytes.bytesize > MAX_BYTES
      parts = (bytes.bytesize.to_f / PART_BYTES).ceil
      common = anchor.merge('document_digest' => Digest::SHA256.hexdigest(bytes), 'part_count' => parts)
      rows = [common.merge('part_index' => 0, 'payload' => '')]
      parts.times do |index|
        rows << common.merge('part_index' => index + 1, 'payload' => Base64.strict_encode64(bytes.byteslice(index * PART_BYTES, PART_BYTES)))
      end
      Publication::Data.freeze_tree(rows)
    end

    def copy_document(document)
      copy = Publication::Data.copy(document, max_bytes: MAX_BYTES, max_nodes: 16_384, max_depth: 12)
      raise Invalid, :invalid_plan_document unless copy.is_a?(Hash)
      copy
    end

    def decode(rows, anchor:, author:)
      anchor!(anchor)
      account = Publication::Data.account(author).downcase
      raise Invalid, :plan_snapshot_limit unless rows.is_a?(Array) && rows.size.between?(1, MAX_PARTS + 1)
      indexed = {}
      rows.each do |row|
        raise Invalid, :invalid_plan_row unless row.is_a?(Hash) && FIELDS.all? { |key| row.key?(key) }
        unless anchor.all? { |key, value| row[key] == value } &&
            row['__id'].is_a?(Integer) && row['__id'] > 0 &&
            row['__insertion_user'].is_a?(String) && row['__insertion_user'].downcase == account
          raise Invalid, :plan_author_or_scope
        end
        count, index = row.values_at('part_count', 'part_index')
        unless count.is_a?(Integer) && count.between?(1, MAX_PARTS) && index.is_a?(Integer) && index.between?(0, count)
          raise Invalid, :invalid_plan_part
        end
        digest!(row['document_digest'])
        raise Invalid, :duplicate_plan_part if indexed.key?(index)
        indexed[index] = row
      end
      header = indexed[0]
      raise Invalid, :incomplete_plan_document unless header && header['payload'] == '' && indexed.size == header['part_count'] + 1
      bytes = ''.b
      (1..header['part_count']).each do |index|
        row = indexed[index]
        unless row && row['part_count'] == header['part_count'] && row['document_digest'] == header['document_digest'] &&
            row['payload'].is_a?(String) && row['payload'].bytesize.between?(1, 2048)
          raise Invalid, :incomplete_plan_document
        end
        begin
          part = Base64.strict_decode64(row['payload'])
        rescue ArgumentError
          raise Invalid, :invalid_plan_encoding
        end
        unless part.bytesize.between?(1, PART_BYTES) && (index == header['part_count'] || part.bytesize == PART_BYTES)
          raise Invalid, :invalid_plan_encoding
        end
        bytes << part
      end
      unless bytes.bytesize <= MAX_BYTES && Digest::SHA256.hexdigest(bytes) == header['document_digest']
        raise Invalid, :plan_document_digest_mismatch
      end
      text = bytes.force_encoding(Encoding::UTF_8)
      raise Invalid, :invalid_plan_encoding unless text.valid_encoding?
      begin
        document = StrictJson.parse(text, max_nesting: 12)
      rescue JSON::ParserError
        raise Invalid, :invalid_plan_document
      end
      raise Invalid, :invalid_plan_document unless document.is_a?(Hash)
      Publication::Data.freeze_tree(Publication::Data.copy(document, max_bytes: MAX_BYTES, max_nodes: 16_384, max_depth: 12))
    end
  end
end
