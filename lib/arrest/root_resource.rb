module Arrest
  class RootResource < AbstractResource

    class << self

      def resource_path
        "#{self.resource_name}"
      end

      # Retrieves a collection of objects and returns them
      # in a hash combined with metadata
      def by_url(context, url)
        begin
          response = source().get(context, url)
          parsed_hash = JSON.parse(response)
          result_count = parsed_hash['result_count']
          body = body_root(response)
        rescue Arrest::Errors::DocumentNotFoundError
          Arrest::logger.info "DocumentNotFoundError for #{url} gracefully returning []"
          return []
        end
        body ||= []
        collection = body.map do |h|
          self.build(context, h)
        end
        {
          :result_count => result_count,
          :collection => collection
        }
      end

      def first(context, filter={})
        all(context,filter).first
      end

      def last(context, filter={})
        all(context,filter).last
      end

      def all(context, filter={})
        Arrest::OrderedCollection.new(context, self, self.resource_path, filter)
      end

      def find(context, id)
        context.cache.lookup(id) do
          begin
            raise "Document Id must not be blank" if id == nil || "" == id

            full_resource_path = "#{self.resource_path}/#{id}"
            r = source().get(context, full_resource_path)
            body = body_root(r)

            raise "Response body must not be empty for #{full_resource_path}" if body == nil || body.empty?

            resource = self.build(context, body.merge({:id => id}))
            resource
          rescue Exception => e
            Arrest::logger.info e.message if e.message
            raise Errors::SpecifiedDocumentNotFoundError.new(id, self.class)
          end
        end
      end

      def filter name, &aproc
        if aproc != nil
          if @filters == nil
            @filters = []
          end
          @filters << Filter.new(name, &aproc)
          send :define_singleton_method, "FILTER_#{name}" do |args = nil|
            collection = args[0]
            call_args = args.drop(1)
            collection.select do |instance|
              instance.instance_exec(*call_args, &aproc)
            end
          end
          send :define_singleton_method, name do |context, args = nil|
            self.all(context).select do |instance|
              instance.instance_exec(args, &aproc)
            end
          end
        else
          raise "You must specify a block for a filter"
        end
      end

      def scope name, options = {}, &block
        super(name, options)
        if block_given?
          send :define_singleton_method, name do |context, filter = {}|
            self.all(context, filter).select(&block)
          end
        else
          send :define_singleton_method, name do |context, filter = {}|
            resource_name = options[:resource_name] || name
            Arrest::OrderedCollection.new(context, self, self.scoped_path(resource_name), filter)
          end
        end

      end

      def scoped_path scope_name
        scope_name = scope_name.to_s
        resource_path + (scope_name.start_with?('?') ? '' : '/') + scope_name
      end

      def stub(context, stub_id)
        n = self.new(context)
        n.initialize_has_attributes({:id => stub_id}) do
          r = n.class.source().get(@context, "#{self.resource_path}/#{stub_id}")
          body = n.class.body_root(r)
          n.init_from_hash(body, true)
        end
        n
      end

      def delete_all(context)
        source().delete_all(context, self.resource_path)
      end
    end

    def resource_path
      "#{self.class.resource_name}"
    end

    def resource_location
      self.class.resource_path + '/' + self.id.to_s
    end

    protected
    def internal_reload
      context.cache.remove(self.id)
      self.class.find(self.context, self.id).to_hash(false, false, :retrieve)
    end
  end
end

