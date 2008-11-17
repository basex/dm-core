module DataMapper
  module Adapters
    # This is probably the simplest functional adapter possible. It simply
    # stores and queries from a hash containing the model classes as keys,
    # and an array of records. It is not persitent whatsoever; when the ruby
    # process finishes, everything that was stored it lost. However, it doesn't
    # require any other external libraries, such as data_objects, so it is ideal
    # for writing specs against. It also serves as an excellent example for
    # budding adapter developers, so it is critical that it remains well documented
    # and up to date.
    class InMemoryAdapter < AbstractAdapter
      ##
      # Used by DataMapper to put records into a data-store: "INSERT" in SQL-speak.
      # It takes an array of the resources (model instances) to be saved. Resources
      # each have a key that can be used to quickly look them up later without
      # searching, if the adapter supports it.
      #
      # @param [Array] resources
      #   The set of resources (model instances)
      #
      # @return [Integer]
      #   The number of records that were actually saved into the data-store
      #
      # @api semipublic
      def create(resources)
        repository_name = self.name

        resources.each do |resource|
          records = model_records(resource.model)

          # TODO: make a model.identity_field method
          if identity_field = resource.model.key(repository_name).detect { |p| p.serial? }
            identity_field.set!(resource, records.size.succ)
          end

          # copy the userspace Resource so that if we call #update we
          # don't silently change the data in userspace
          records[resource.key] = resource.dup
        end

        resources.size
      end

      ##
      # Used by DataMapper to update the attributes on existing records in a
      # data-store: "UPDATE" in SQL-speak. It takes a hash of the attributes
      # to update with, as well as a query object that specifies which resources
      # should be updated.
      #
      # @param [Hash] attributes
      #   A set of key-value pairs of the attributes to update the resources with.
      # @param [DataMapper::Query] query
      #   The query that should be used to find the resource(s) to update.
      #
      # @return [Integer] the number of records that were successfully updated
      #
      # @api semipublic
      def update(attributes, query)
        records = model_records(query.model)

        resources = read_many(query).each do |r|
          resource = records[r.key]
          attributes.each { |p,v| p.set!(resource, v) }
        end

        resources.size
      end

      ##
      # Look up a single record from the data-store. "SELECT ... LIMIT 1" in SQL.
      # Used by Model#get to find a record by its identifier(s), and Model#first
      # to find a single record by some search query.
      #
      # @param [DataMapper::Query] query
      #   The query to be used to locate the resource.
      #
      # @return [DataMapper::Resource]
      #   A Resource object representing the record that was found, or nil for no
      #   matching records.
      #
      # @api semipublic
      def read_one(query)
        read(query, query.model, false)
      end

      ##
      # Looks up a collection of records from the data-store: "SELECT" in SQL.
      # Used by Model#all to search for a set of records; that set is in a
      # DataMapper::Collection object.
      #
      # @param [DataMapper::Query] query
      #   The query to be used to seach for the resources
      #
      # @return [DataMapper::Collection]
      #   A collection of all the resources found by the query.
      #
      # @api semipublic
      def read_many(query)
        Collection.new(query) do |collection|
          read(query, collection, true)
        end
      end

      ##
      # Destroys all the records matching the given query. "DELETE" in SQL.
      #
      # @param [DataMapper::Query] query
      #   The query used to locate the resources to be deleted.
      #
      # @return [Integer]
      #   The number of records that were deleted.
      #
      # @api semipublic
      def delete(query)
        records = model_records(query.model)
        read_many(query).each { |r| records.delete(r.key) }.size
      end

      private

      ##
      # Make a new instance of the adapter. The @model_records ivar is the 'data-store'
      # for this adapter. It is not shared amongst multiple incarnations of this
      # adapter, eg DataMapper.setup(:default, :adapter => :in_memory);
      # DataMapper.setup(:alternate, :adapter => :in_memory) do not share the
      # data-store between them.
      #
      # @param <String, Symbol> name
      #   The name of the DataMapper::Repository using this adapter.
      # @param <String, Hash> uri_or_options
      #   The connection uri string, or a hash of options to set up
      #   the adapter
      #
      # @api semipublic
      def initialize(name, uri_or_options)
        super
        @model_records = {}
      end

      ##
      # #TODO: Extract this into its own module, so it can be re-used in all
      #        adapters that don't have a native query language
      #
      # This is the normal way of parsing the DataMapper::Query object into
      # a set of conditions. This particular one translates it into ruby code
      # that can be performed on ruby objects. It can be reused in most other
      # adapters, however, if the adapter has its own native query language,
      # such as SQL, an adapter developer is probably better using this as an
      # example of how to parse the DataMapper::Query object.
      #
      # @api private
      def read(query, collection, many = true)
        conditions = query.conditions

        # find all matching records
        resources = model_records(query.model).values.select do |resource|
          conditions.all? do |condition|
            operator, property, bind_value = *condition

            value = property.get!(resource)

            case operator
              when :eql, :in then equality_comparison(bind_value, value)
              when :not      then !equality_comparison(bind_value, value)
              when :like     then Regexp.new(bind_value) =~ value
              when :gt       then !value.nil? && value >  bind_value
              when :gte      then !value.nil? && value >= bind_value
              when :lt       then !value.nil? && value <  bind_value
              when :lte      then !value.nil? && value <= bind_value
            end
          end
        end

        # if the requested resource is outside the range of available
        # resources return nil
        if query.offset > resources.size - 1
          return
        end

        # sort the resources
        if query.order.any?
          resources = sorted_resources(resources, query.order)
        end

        # limit the resources
        if query.limit || query.offset > 0
          resources = resources[query.offset, query.limit || resources.size]
        end

        properties = query.fields

        # load a Resource for each result
        resources.each do |resource|
          # copy the value from the InMemoryAdapter Resource
          values = properties.map { |p| p.get!(resource) }
          many ? collection.load(values) : (break collection.load(values, query))
        end
      end

      # TODO: document
      # @api private
      def equality_comparison(bind_value, value)
        case bind_value
          when Array, Range then bind_value.include?(value)
          else                   bind_value == value
        end
      end

      # TODO: document
      # @api private
      def sorted_resources(resources, order)
        sort_order = order.map { |i| [ i.property, i.direction == :desc ] }

        # sort resources by each property
        resources.sort do |a,b|
          cmp = 0
          sort_order.each do |(property,descending)|
            cmp = property.get!(a) <=> property.get!(b)
            next if cmp == 0
            cmp *= -1 if descending
          end
          cmp
        end
      end

      # TODO: document
      # @api private
      def model_records(model)
        @model_records[model] ||= {}
      end
    end
  end
end
