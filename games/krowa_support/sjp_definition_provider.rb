# encoding: UTF-8

require_relative "errors"
require_relative "normalizer"
require_relative "sjp_noun_forms"

module GameRoomKrowa
  class SjpDefinitionProvider
    BASE_URL = "https://sjp.pl/"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_REDIRECTS = 3
    DEFINITION_PATTERN = %r{
      <p\b[^>]*>\s*<b>\s*znaczenie:\s*</b>(?:(?!</p>).)*</p>\s*</div>\s*
      <p\b[^>]*>(.*?)</p>
    }imx.freeze
    TABLE_PATTERN = %r{<table\b(?=[^>]*\bclass\s*=\s*["'][^"']*\bwtab\b)[^>]*>.*?</table>}im.freeze
    Entry = Struct.new(:lemma, :forms, :indeclinable, :definition, keyword_init: true)
    private_constant :Entry

    def initialize(fetcher: nil)
      @fetcher = fetcher || method(:download)
      @cache = {}
    end

    def definition_for(word)
      normalized = Normalizer.call(utf8_text(word))
      return @cache[normalized] if @cache.key?(normalized)

      html = @fetcher.call(uri_for(normalized))
      definition = parse(html, word: normalized)
      @cache[normalized] = definition
    rescue DefinitionError
      raise
    rescue StandardError => error
      raise DefinitionError, error.message
    end

    def parse(html, word: nil)
      entries = entries_from(utf8_text(html))
      normalized = Normalizer.call(utf8_text(word))
      preferred = entries.select do |entry|
        !normalized.empty? && SjpNounForms.nominative?(
          normalized, entry.lemma, entry.forms, indeclinable: entry.indeclinable
        )
      end
      selected = preferred.empty? ? entries : preferred
      raise DefinitionNotFoundError, "Definition was not found on SJP" if selected.empty?

      selected.group_by(&:lemma).map do |lemma, meanings|
        ([lemma] + meanings.map(&:definition).uniq).reject(&:empty?).join("\n")
      end.join("\n\n")
    end

    private

    def entries_from(source)
      tables = source.to_enum(:scan, TABLE_PATTERN).map { Regexp.last_match }
      # Retain support for the older, definition-only markup. It has no
      # grammatical metadata, so all usable meanings remain fallback entries.
      if tables.empty?
        return source.scan(DEFINITION_PATTERN).filter_map do |capture|
          definition = definition_text(capture.first)
          Entry.new(lemma: "", forms: {}, indeclinable: false, definition: definition) if definition
        end
      end

      tables.each_with_index.filter_map do |table, index|
        boundary = tables[index + 1]&.begin(0) || source.length
        tail = source[table.end(0)...boundary]
        match = DEFINITION_PATTERN.match(tail)
        # A missing meaning must not consume the following entry or comments.
        next unless match && tail[0...match.begin(0)].strip.empty?

        definition = definition_text(match[1])
        next unless definition

        markup = table[0]
        heading = markup.match(%r{<tr\b[^>]*>\s*<th\b[^>]*>\s*<b\b[^>]*>(.*?)</b>}im)
        lemma = heading ? plain_text(heading[1]) : ""
        forms = {}
        markup.scan(%r{<tr\b[^>]*>.*?</tr>}im).each do |row|
          inflection = row.match(%r{<tt\b[^>]*>\s*([A-Za-z])\s*</tt>\s*</th>\s*<td\b[^>]*>(.*?)</td>}im)
          next unless inflection

          flag = inflection[1]
          # Keep SJP's spelling: e.g. the proper name Pola is not the
          # lowercase nominative plural pola, and Piły is not piły.
          (forms[flag] ||= []).concat(plain_text(inflection[2]).split(",").map(&:strip))
        end
        indeclinable = markup.match?(%r{<th\b[^>]*>\s*odmienno\u015B\u0107\s*</th>\s*<td\b[^>]*>\s*nie\s*</td>}imu)
        Entry.new(lemma: lemma, forms: forms, indeclinable: indeclinable, definition: definition)
      end
    end

    def definition_text(html)
      text = plain_text(html)
      # SJP uses a dash paragraph between entries, including after an entry
      # without a definition. It is a separator, not a meaning.
      text unless text.empty? || text == "-" || text == "(brak)"
    end

    def plain_text(html)
      text = html
        .gsub(%r{<br\s*/?>}i, "\n")
        .gsub(%r{<[^>]+>}, " ")
      unescape_html(text)
        .lines
        .map { |line| line.gsub(/[[:space:]]+/, " ").strip }
        .reject(&:empty?)
        .join("\n")
    end

    def utf8_text(value)
      text = value.to_s.dup
      # Net::HTTP returns response bodies as ASCII-8BIT even when the bytes
      # contain UTF-8. Mark those bytes before transcoding and sanitizing them.
      text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�").scrub
    end

    def uri_for(word)
      ensure_uri!
      encoded = word.encode(Encoding::UTF_8).bytes.map do |byte|
        character = byte.chr
        character.match?(/[A-Za-z0-9_.~-]/) ? character : format("%%%02X", byte)
      end.join
      URI("#{BASE_URL}#{encoded}")
    end

    def download(uri, redirects = MAX_REDIRECTS)
      begin
        require "net/http"
      rescue LoadError => error
        raise DefinitionError, "HTTP library is unavailable: #{error.message}"
      end
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Elten Krowa/0.4"
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        utf8_text(response.body)
      when Net::HTTPRedirection
        raise DefinitionError, "Too many redirects from SJP" if redirects <= 0

        download(URI.join(uri, response["location"].to_s), redirects - 1)
      else
        raise DefinitionError, "SJP returned HTTP #{response.code}"
      end
    end

    def ensure_uri!
      return if defined?(URI)

      require "uri"
    rescue LoadError => error
      raise DefinitionError, "URI library is unavailable: #{error.message}"
    end

    def unescape_html(text)
      text.to_s
        .gsub(/&#(\d+);/) { valid_codepoint(Regexp.last_match(1).to_i) }
        .gsub(/&#x([0-9a-f]+);/i) { valid_codepoint(Regexp.last_match(1).to_i(16)) }
        .gsub("&nbsp;", " ")
        .gsub("&quot;", '"')
        .gsub("&apos;", "'")
        .gsub("&#39;", "'")
        .gsub("&lt;", "<")
        .gsub("&gt;", ">")
        .gsub("&amp;", "&")
    end

    def valid_codepoint(codepoint)
      [codepoint].pack("U")
    rescue RangeError
      "�"
    end
  end
end
