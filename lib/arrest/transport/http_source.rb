require 'faraday'
require 'arrest/handler'

module Arrest

  class HttpSource

    attr_reader :base

    def initialize base
      @base = base
    end

    def url
      @base
    end

    def add_headers(context, headers)
      decorator = context.header_decorator if context
      decorator ||= Arrest::Source.header_decorator
      hds = decorator.headers
      hds.each_pair do |k,v|
        headers[k.to_s] = v.to_s
      end
      hds
    end

    def get(context, sub, filter={})
      sub = fix_url_encode(sub)
      profiler_status_str = ""
      ::ActiveSupport::Notifications.instrument("http.sgdb",
                                                :method => :get, :url => sub, :status => profiler_status_str) do
        headers = nil
        response = self.connection().get do |req|
          req.url(sub, filter)
          headers = add_headers(context, req.headers)
        end
        rql = RequestLog.new(:get, "#{sub}#{hash_to_query filter}", nil, headers)
        rsl = ResponseLog.new(response.env[:status], response.body)
        Arrest::Source.call_logger.log(rql, rsl)
        if response.env[:status] == 401
          raise Errors::PermissionDeniedError.new(response.body)
        elsif response.env[:status] == 404
          raise Errors::DocumentNotFoundError
        elsif response.env[:status] != 200
          raise Errors::UnknownError.new(response.body)
        end
        profiler_status_str << response.env[:status].to_s
        response.body
      end
    end

    def delete_all(context, resource_path)
      headers = nil
      response = self.connection().delete do |req|
        req.url(resource_path)
        headers = add_headers(context, req.headers)
      end
      rql = RequestLog.new(:delete, "#{resource_path}", nil, headers)
      rsl = ResponseLog.new(response.env[:status], response.body)
      Arrest::Source.call_logger.log(rql, rsl)

      response.env[:status] == 200
    end

    def delete(context, rest_resource)
      profiler_status_str = ""
      ::ActiveSupport::Notifications.instrument("http.sgdb",
                                            :method => :delete, :url => rest_resource.resource_location, :status => profiler_status_str) do
        raise "To delete an object it must have an id" unless rest_resource.respond_to?(:id) && rest_resource.id != nil
        headers = nil
        response = self.connection().delete do |req|
          req.url(rest_resource.resource_location)
          headers = add_headers(context, req.headers)
        end
        rql = RequestLog.new(:delete, rest_resource.resource_location, nil, headers)
        rsl = ResponseLog.new(response.env[:status], response.body)
        Arrest::Source.call_logger.log(rql, rsl)
        if response.env[:status] != 200
          handle_errors(rest_resource, response.body, response.env[:status])
        end
        profiler_status_str << response.env[:status].to_s
        response.env[:status] == 200
      end
    end

    def put(context, rest_resource)
      raise "To change an object it must have an id" unless rest_resource.respond_to?(:id) && rest_resource.id != nil
      hash = rest_resource.to_jhash(:update)
      hash.delete(:id)
      hash.delete("id")
      body = JSON.generate(hash)

      profiler_status_str = ""
      ::ActiveSupport::Notifications.instrument("http.sgdb",
                                                :method => :delete,
                                                :url => rest_resource.resource_location,
                                                :status => profiler_status_str) do
        headers = nil
        location = rest_resource.resource_location
        response = self.connection().put do |req|
          req.url(location)
          headers = add_headers(rest_resource.context, req.headers)
          req.body = body
        end
        rql = RequestLog.new(:put, location, body, headers)
        rsl = ResponseLog.new(response.env[:status], response.body)
        Arrest::Source.call_logger.log(rql, rsl)
        if response.env[:status] != 200
          handle_errors(rest_resource, response.body, response.env[:status])
        end
        profiler_status_str << response.env[:status].to_s
        response.env[:status] == 200
      end
    end

    def post(context, rest_resource)
      profiler_status_str = ""
      ::ActiveSupport::Notifications.instrument("http.sgdb",
                                                :method => :post,
                                                :url => rest_resource.resource_path,
                                                :status => profiler_status_str) do
        raise "new object must have setter for id" unless rest_resource.respond_to?(:id=)
        raise "new object must not have id" if rest_resource.respond_to?(:id) && rest_resource.id != nil
        hash = rest_resource.to_jhash(:create)
        hash.delete(:id)
        hash.delete('id')

        body = JSON.generate(hash)
        headers = nil
        response = self.connection().post do |req|
          req.url rest_resource.resource_path
          headers = add_headers(context, req.headers)
          req.body = body
        end
        rql = RequestLog.new(:post, rest_resource.resource_path, body, headers)
        rsl = ResponseLog.new(response.env[:status], response.body)
        Arrest::Source.call_logger.log(rql, rsl)
        if (response.env[:status] == 201)
          location = response.env[:response_headers][:location]
          id = location.gsub(/^.*\//, '')
          rest_resource.id= id
          true
        else
          handle_errors(rest_resource, response.body, response.env[:status])
          false
        end
      end
    end

    def connection
      conn = Faraday.new(:url => @base) do |builder|
        builder.request  :url_encoded
        builder.adapter  :net_http
        builder.use Faraday::Response::Logger, Arrest::logger
      end
    end

    def hash_to_query hash
      return "" if hash.empty?
      r = ""
      c = '?'
      hash.each_pair do |k,v|
        r << c
        r << k.to_s
        r << '='
        r << v.to_s
        c = '&'
      end
      r
    end

    private

      def fix_url_encode(input_url)
        q_mark_idx = input_url.rindex('?')
        if q_mark_idx
          head,query = input_url.split('?')
          head + '?' + query.gsub('+', '%2B')
        else
          input_url
        end

      end

      def handle_errors rest_resource, body, status
        err = Arrest::Source.error_handler.convert(body,status)
        if err.is_a?(String)
          rest_resource.errors.add(:base, err)
        else
          err.map do |k,v|
            if v.is_a?(String)
              rest_resource.errors.add(k,v)
            else
              v.map do |msg|
                rest_resource.errors.add(k,msg)
              end
            end
          end
        end
      end

  end
end
