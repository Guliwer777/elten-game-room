# frozen_string_literal: true

require 'zlib'
require_relative 'model'

module GameRoomQuizContributions
  class Repository
    using GameRoomLocalization::Translations
    PREFIX = 'quiz-draft-'
    RECEIPT_PREFIX = 'quiz-sent-'

    # Native SDK only; these modules do not all forward managed task options.
    class RequestClient
      def initialize(client, token, check)
        @client, @token, @check = client, token, check
      end
      def api_data(method, path, params = nil)
        @check.call(@token)
        result = @client.api_data(method, path, params, timeout: 15, cancellation_token: @token)
        @check.call(@token)
        result
      end
      def api_payload(method, path, params = nil)
        @check.call(@token)
        result = @client.api_payload(method, path, params, timeout: 15, cancellation_token: @token)
        @check.call(@token)
        result
      end
      def api_binary_data(method, path, body, headers = {}, params = nil)
        @check.call(@token)
        result = @client.api_binary_data(method, path, body, headers, params, timeout: 30, cancellation_token: @token)
        @check.call(@token)
        result
      end
    end

    attr_reader :user
    def initialize(app_uuid:, user:, current_user:, client: nil, api: nil)
      @uuid, @user, @current_user = app_uuid, user.to_s.downcase, current_user
      @client, @api = client || EltenLink::Client.new, api || EltenLink::Apps
    end

    def request_client(token)
      RequestClient.new(@client, token, method(:check))
    end

    def list(token: nil)
      rows = resources(token).list(timeout: 15, cancellation_token: token)
      check(token)
      rows.select do |resource|
        resource.resource.to_s.start_with?(PREFIX)
      end.map do |resource|
        meta = metadata(resource)
        {'resource_id' => resource.id, 'resource_name' => resource.resource, 'id' => meta['id'],
          'title' => meta['title'], 'kind' => meta['kind'], 'language' => meta['language'], 'count' => meta['count']}
      end
    end

    def read(ref, token: nil)
      store = resources(token)
      resource = store.list(timeout: 15, cancellation_token: token).find { |r| r.id == ref.fetch('resource_id') }
      check(token)
      raise Unavailable, _('This draft is no longer on the server. Your open copy has not been changed.') unless resource
      meta = metadata(resource)
      raise Invalid, _('Invalid proposal.') unless meta['id'] == ref['id'] && resource.resource == ref['resource_name']
      bytes = store.download(resource, timeout: 15, cancellation_token: token)
      check(token)
      raise Invalid, _('The saved draft is damaged.') unless Digest::SHA256.hexdigest(bytes) == meta['sha256']
      value = Model.draft(JSON.parse(inflate(bytes)))
      raise Invalid, _('The saved draft is damaged.') unless value['id'] == meta['id']
      value.merge('resource_id' => resource.id, 'resource_name' => resource.resource)
    rescue JSON::ParserError, Zlib::Error
      raise Invalid, _('The saved draft is damaged.')
    end

    def save(value, token: nil)
      content = Model.draft(value)
      snapshot = value.fetch('snapshot')
      raise Invalid, _('Invalid proposal.') unless Model::UUID.match?(snapshot)
      name = "#{PREFIX}#{content['id']}-#{snapshot}.json.deflate"
      bytes = Zlib::Deflate.deflate(JSON.generate(content))
      meta = JSON.generate('format' => 1, 'id' => content['id'], 'title' => Model.title(content),
        'language' => Model.language(content), 'kind' => content['kind'],
        'count' => content['items'].size, 'sha256' => Digest::SHA256.hexdigest(bytes))
      raise Invalid, _('This draft is too large.') if meta.bytesize > 1024
      store = resources(token)
      # Same names are NOT overwrites. Keep the operation name across a retry
      # so an upload with a lost response can be found and verified.
      existing = store.list(timeout: 15, cancellation_token: token).find { |r| r.resource == name && r.meta == meta }
      check(token)
      resource = existing || store.upload(name, bytes, meta: meta, timeout: 30, cancellation_token: token)
      result = content.merge('resource_id' => resource.id, 'resource_name' => name)
      confirmed = read(result, token: token)
      raise Invalid, _('The saved draft is damaged.') unless Model.draft(confirmed) == content
      delete(value, token: token) if value['resource_id'] && value['resource_id'] != resource.id
      confirmed
    end

    def delete(ref, token: nil)
      return true unless ref['resource_id']
      store = resources(token)
      found = store.list(timeout: 15, cancellation_token: token).find { |r| r.id == ref['resource_id'] }
      check(token)
      return true unless found
      raise Invalid, _('Invalid proposal.') unless found.resource == ref['resource_name'] && metadata(found)['id'] == ref['id']
      store.delete(found, timeout: 15, cancellation_token: token)
      check(token)
      true
    end

    # Keep account-wide evidence before removing the sender's message. A
    # resumed draft on another computer must not send the same content again.
    def delivered?(key, token: nil)
      name, bytes = receipt(key)
      store = resources(token)
      rows = store.list(timeout: 15, cancellation_token: token)
      check(token)
      row = rows.find { |r| r.resource == name }
      return false unless row
      raise Invalid, _('Invalid delivery receipt.') unless row.uploader.to_s.casecmp?(@user) && row.filesize.to_i == bytes.bytesize
      actual = store.download(row, timeout: 15, cancellation_token: token)
      check(token)
      raise Invalid, _('Invalid delivery receipt.') unless actual.b == bytes.b
      true
    end

    def record_delivery(key, token: nil)
      return true if delivered?(key, token: token)
      name, bytes = receipt(key)
      resources(token).upload(name, bytes, meta: '', timeout: 30, cancellation_token: token)
      check(token)
      raise Unavailable, _('The delivery receipt could not be saved.') unless delivered?(key, token: token)
      true
    end

    def check(token = nil)
      token&.raise_if_cancelled!
      raise Unavailable, _('The signed-in account has changed.') if @user.empty? || @current_user.call.to_s.downcase != @user
    end

    private

    def receipt(key)
      raise Invalid, _('Invalid delivery receipt.') unless /\A[0-9a-f]{64}\z/.match?(key.to_s)
      ["#{RECEIPT_PREFIX}#{key}.json", JSON.generate('format' => 1, 'author' => @user, 'submission_id' => key)]
    end

    def resources(token)
      check(token)
      @api.private_resources(@client, @uuid)
    end

    def metadata(resource)
      meta = JSON.parse(resource.meta.to_s)
      raise Invalid, _('The saved draft is damaged.') unless resource.resource.to_s.start_with?(PREFIX) &&
        resource.uploader.to_s.casecmp?(@user) && resource.filesize.to_i.between?(1, Model::MAX_BYTES) &&
        meta.is_a?(Hash) && meta['format'] == 1 && Model::UUID.match?(meta['id'].to_s) &&
        resource.resource.start_with?(PREFIX + meta['id'] + '-') && /\A[0-9a-f]{64}\z/.match?(meta['sha256'].to_s)
      meta
    rescue JSON::ParserError
      raise Invalid, _('The saved draft is damaged.')
    end

    def inflate(bytes)
      raise Invalid, _('This draft is too large.') if bytes.bytesize > Model::MAX_BYTES
      stream = Zlib::Inflate.new
      result = ''.b
      begin
        stream.inflate(bytes) do |part|
          raise Invalid, _('This draft is too large.') if result.bytesize + part.bytesize > Model::MAX_BYTES
          result << part
        end
        raise Invalid, _('The saved draft is damaged.') unless stream.finished? && stream.total_in == bytes.bytesize
      ensure
        stream.close
      end
      result.force_encoding(Encoding::UTF_8)
    end
  end
end
