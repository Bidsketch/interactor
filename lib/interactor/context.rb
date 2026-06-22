require "set"

module Interactor
  # Public: The object for tracking state of an Interactor's invocation. The
  # context is used to initialize the interactor with the information required
  # for invocation. The interactor manipulates the context to produce the result
  # of invocation.
  #
  # The context is the mechanism by which success and failure are determined and
  # the context is responsible for tracking individual interactor invocations
  # for the purpose of rollback.
  #
  # The context may be manipulated using arbitrary getter and setter methods.
  #
  # A context is not safe for concurrent writes: the first write of a key may
  # define a singleton accessor (see RESERVED_NAMES), which mutates the
  # instance's singleton class. Share a context across threads for reads only,
  # or guard writes externally.
  #
  # Examples
  #
  #   context = Interactor::Context.new
  #   # => #<Interactor::Context>
  #   context.foo = "bar"
  #   # => "bar"
  #   context
  #   # => #<Interactor::Context foo="bar">
  #   context.hello = "world"
  #   # => "world"
  #   context
  #   # => #<Interactor::Context foo="bar" hello="world">
  #   context.foo = "baz"
  #   # => "baz"
  #   context
  #   # => #<Interactor::Context foo="baz" hello="world">
  class Context
    # Internal: Initialize an Interactor::Context or preserve an existing one.
    # If the argument given is an Interactor::Context, the argument is returned.
    # Otherwise, a new Interactor::Context is initialized from the provided
    # hash.
    #
    # The "build" method is used during interactor initialization.
    #
    # context - A Hash whose key/value pairs are used in initializing a new
    #           Interactor::Context object. If an existing Interactor::Context
    #           is given, it is simply returned. (default: {})
    #
    # Examples
    #
    #   context = Interactor::Context.build(foo: "bar")
    #   # => #<Interactor::Context foo="bar">
    #   context.object_id
    #   # => 2170969340
    #   context = Interactor::Context.build(context)
    #   # => #<Interactor::Context foo="bar">
    #   context.object_id
    #   # => 2170969340
    #
    # Returns the Interactor::Context.
    def self.build(context = {})
      if self === context
        context
      else
        new(context)
      end
    end

    def initialize(context = {})
      # Assign every instance variable up front, in a fixed order, so all
      # contexts share one object shape. fail!/halt!/rollback! then only mutate
      # existing slots instead of adding ivars, which would fork the shape and
      # make @table and flag reads polymorphic (slower) under YJIT.
      @table = {}
      reset_state
      context&.each { |key, value| self[key] = value }
    end

    # Public: Read a context attribute by key.
    def [](key)
      @table[key.to_sym]
    end

    # Public: Write a context attribute by key, normalising to symbol.
    def []=(key, value)
      key = key.to_sym
      define_accessor(key) if define_accessor?(key)
      @table[key] = value
    end

    # Public: Return all user-set attributes as a Hash (excludes internal
    # state). Mirrors OpenStruct#to_h: with a block, each key/value pair is
    # transformed; without one, a shallow copy is returned.
    def to_h(&block)
      return @table.to_h(&block) if block

      @table.dup
    end

    # Public: Extract a nested value, mirroring OpenStruct#dig (and Hash#dig).
    # The first key is normalised to a symbol to match attribute storage.
    def dig(key, *rest)
      @table.dig(key.to_sym, *rest)
    end

    def ==(other)
      other.is_a?(Context) && @table == other.table
    end

    def eql?(other)
      other.is_a?(Context) && @table.eql?(other.table)
    end

    def hash
      @table.hash
    end

    # Public: Freeze the context. Freezes the backing table too so that, as with
    # OpenStruct, subsequent writes raise FrozenError rather than silently
    # succeeding.
    def freeze
      @table.freeze
      super
    end

    # Public: Serialize only the attribute table. Because set keys define
    # singleton methods, the default Marshal path raises "singleton can't be
    # dumped"; dumping just @table keeps contexts marshallable (e.g. cached or
    # enqueued) and rebuilds accessors on load. Transient state (called list,
    # failure/halted flags) is intentionally not preserved.
    def marshal_dump
      @table
    end

    def marshal_load(table)
      @table = table
      reset_state
      rebuild_accessors
    end

    def inspect
      pairs = @table.map { |k, v| "#{k}=#{v.inspect}" }
      "#<#{self.class}#{" #{pairs.join(", ")}" unless pairs.empty?}>"
    end

    # OpenStruct aliased to_s to inspect; preserve that so Interactor::Failure
    # messages (Exception#message calls context.to_s) stay readable rather than
    # falling back to Object#to_s (#<Interactor::Context:0x...>).
    alias_method :to_s, :inspect

    def respond_to_missing?(method_name, include_private = false)
      method_name.to_s.end_with?("=") || @table.key?(method_name.to_sym) || super
    end

    # Dynamic getter/setter for arbitrary context attributes.
    # Setters end with "="; getters return nil for unset keys.
    def method_missing(method_name, *args)
      name = method_name.to_s
      if name.end_with?("=")
        self[name.delete_suffix("=").to_sym] = args.first
      else
        # Mirror OpenStruct: a getter takes no arguments, so flag caller bugs
        # rather than silently ignoring them.
        unless args.empty?
          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0)"
        end

        @table[method_name.to_sym]
      end
    end

    # Public: Whether the Interactor::Context is successful. By default, a new
    # context is successful and only changes when explicitly failed.
    #
    # The "success?" method is the inverse of the "failure?" method.
    #
    # Examples
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context.success?
    #   # => true
    #   context.fail!
    #   # => Interactor::Failure: #<Interactor::Context>
    #   context.success?
    #   # => false
    #
    # Returns true by default or false if failed.
    def success?
      !failure?
    end

    # Public: Whether the Interactor::Context has failed. By default, a new
    # context is successful and only changes when explicitly failed.
    #
    # The "failure?" method is the inverse of the "success?" method.
    #
    # Examples
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context.failure?
    #   # => false
    #   context.fail!
    #   # => Interactor::Failure: #<Interactor::Context>
    #   context.failure?
    #   # => true
    #
    # Returns false by default or true if failed.
    def failure?
      @failure || false
    end

    # Public: Whether the Interactor::Context was halted or not. By default, a new
    # context is non-halted and only changes when explicitly halted.
    #
    # Examples
    #
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context.halted?
    #   # => false
    #   context.halt!(foo: "baz")
    #   # => Interactor::Halt: #<Interactor::Context foo="baz">
    #
    # Raises Interactor::Halt initialized with the Interactor::Context
    def halted?
      @halted || false
    end

    # Public: Fail the Interactor::Context. Failing a context raises an error
    # that may be rescued by the calling interactor. The context is also flagged
    # as having failed.
    #
    # Optionally the caller may provide a hash of key/value pairs to be merged
    # into the context before failure.
    #
    # context - A Hash whose key/value pairs are merged into the existing
    #           Interactor::Context instance. (default: {})
    #
    # Examples
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context.fail!
    #   # => Interactor::Failure: #<Interactor::Context>
    #   context.fail! rescue false
    #   # => false
    #   context.fail!(foo: "baz")
    #   # => Interactor::Failure: #<Interactor::Context foo="baz">
    #
    # Raises Interactor::Failure initialized with the Interactor::Context.
    def fail!(context = {})
      context.each { |key, value| self[key] = value }
      @failure = true
      raise Failure, self
    end

    # Public: Halt the Interactor::Context. Halting a context allows stopping the
    # context without failing it. It is often used in stopping Organizer chains
    # without explicitly failing. The context is not flagged as having failed.
    #
    # Optionally the caller may provide a hash of key/value pairs to be merged
    # into the context before halting.
    #
    # context - A Hash whose key/value pairs are merged into the existing
    #           Interactor::Context instance. (default: {})
    #
    # Examples
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context.halt!
    #   # => Interactor::Halt: #<Interactor::Context>
    #   context.halt! rescue false
    #   # => false
    #   context.halt!(foo: "baz")
    #   # => Interactor::Halt: #<Interactor::Context foo="baz">
    #
    # Raises Interactor::Halt initialized with the Interactor::Context.
    def halt!(context = {})
      context.each { |key, value| self[key] = value }
      @halted = true
      raise Halt, self
    end

    # Internal: Track that an Interactor has been called. The "called!" method
    # is used by the interactor being invoked with this context. After an
    # interactor is successfully called, the interactor instance is tracked in
    # the context for the purpose of potential future rollback.
    #
    # interactor - An Interactor instance that has been successfully called.
    #
    # Returns nothing.
    def called!(interactor)
      _called << interactor
    end

    # Public: Roll back the Interactor::Context. Any interactors to which this
    # context has been passed and which have been successfully called are asked
    # to roll themselves back by invoking their "rollback" instance methods.
    #
    # Examples
    #
    #   context = MyInteractor.call(foo: "bar")
    #   # => #<Interactor::Context foo="baz">
    #   context.rollback!
    #   # => true
    #   context
    #   # => #<Interactor::Context foo="bar">
    #
    # Returns true if rolled back successfully or false if already rolled back.
    def rollback!
      return false if @rolled_back || halted?

      _called.reverse_each(&:rollback)
      @rolled_back = true
    end

    # Internal: An Array of successfully called Interactor instances invoked
    # against this Interactor::Context instance.
    #
    # Examples
    #
    #   context = Interactor::Context.new
    #   # => #<Interactor::Context>
    #   context._called
    #   # => []
    #
    #   context = MyInteractor.call(foo: "bar")
    #   # => #<Interactor::Context foo="baz">
    #   context._called
    #   # => [#<MyInteractor @context=#<Interactor::Context foo="baz">>]
    #
    # Returns an Array of Interactor instances or an empty Array.
    def _called
      @called ||= []
    end

    # Internal: Support for ruby 3.0 pattern matching
    #
    # Examples
    #
    #   context = MyInteractor.call(foo: "bar")
    #
    #   # => #<Interactor::Context foo="bar">
    #   context => { foo: }
    #   foo == "bar"
    #   # => true
    #
    #
    #   case context
    #   in success: true, result: { first:, second: }
    #     do_stuff(first, second)
    #   in failure: true, error_message:
    #     log_error(message: error_message)
    #   in halted: true
    #     handle_early_exit
    #   end
    #
    # Returns the context as a hash, including success, failure, and halted
    def deconstruct_keys(_keys)
      @table.merge(
        success: success?,
        failure: failure?,
        halted: halted?
      )
    end

    protected

    # Readable by sibling contexts only, so #== / #eql? can compare tables
    # without reaching into another instance's @table by name.
    attr_reader :table

    private

    # Whether a singleton accessor should be installed for the given key.
    #
    # A plain key (one that does not shadow an existing method) is served by
    # #method_missing, so no accessor is needed - keeping ordinary contexts free
    # of per-key singleton methods. An accessor is installed only when the key
    # would otherwise be intercepted by an inherited method (e.g. ActiveSupport's
    # Object#to_json), so the stored value reads back. Reserved names and keys
    # already backed by an accessor are skipped.
    #
    # The collision test reads the class's real method table rather than
    # #respond_to?, which #respond_to_missing? would report true for any stored
    # key, and avoids touching #singleton_class until we know shadowing is
    # needed - materialising a per-instance singleton class for an ordinary key
    # would give every context its own class and make attribute reads
    # megamorphic under YJIT.
    def define_accessor?(key)
      return false if RESERVED_NAMES.include?(key)
      return false unless shadows_inherited_method?(key)

      !singleton_class.method_defined?(key, false)
    end

    # Whether a real (non-method_missing) method named key is inherited, so a
    # plain getter would dispatch to it instead of the stored value.
    def shadows_inherited_method?(key)
      self.class.method_defined?(key) || self.class.private_method_defined?(key)
    end

    # Define a getter on this instance's singleton class so it outranks the
    # inherited method the key shadows. Only the reader needs overriding: setter
    # names end in "=", which no inherited method does, so writes always route
    # through #method_missing to #[]=. See #define_accessor? for when this runs.
    def define_accessor(key)
      define_singleton_method(key) { @table[key] }
    end

    # Install singleton accessors for every stored key that needs one. Used
    # after @table is replaced wholesale (dup/clone, Marshal load) rather than
    # built up key-by-key through #[]=.
    def rebuild_accessors
      @table.each_key { |key| define_accessor(key) if define_accessor?(key) }
    end

    def initialize_copy(orig)
      super
      @table = orig.to_h
      rebuild_accessors
      reset_state
      # A copy starts fresh except that it carries over the called interactors,
      # so it can still be rolled back.
      @called = orig._called.dup
    end

    # Set the transient state to that of a brand-new context, assigning the
    # ivars in the order #initialize establishes so every construction path
    # produces the same object shape.
    def reset_state
      @called = []
      @failure = false
      @halted = false
      @rolled_back = false
    end

    # Internal: Inherited Object/Kernel methods the context itself calls and
    # must never let a key shadow. Only this protocol half needs hand-listing -
    # it lives on Object, not here; the class's own methods are folded in by
    # RESERVED_NAMES below.
    CORE_PROTOCOL = %i[
      dup clone frozen? class is_a? kind_of? instance_of? nil?
      send __send__ singleton_class define_singleton_method
      instance_variable_get instance_variable_set method methods
      respond_to? object_id equal?
    ].freeze

    # Internal: Method names a context key must never shadow with a singleton
    # accessor. Derived from the class's own API (so adding or renaming a method
    # can't drift out of sync with this list) plus the inherited protocol above.
    # Such keys are still stored in @table and reachable via #[]/#to_h. Names
    # from *other* libraries (e.g. ActiveSupport's Object#to_json) are absent on
    # purpose: those are shadowed so a stored value reads back, which is the
    # entire reason accessors exist.
    RESERVED_NAMES = (
      instance_methods(false) + private_instance_methods(false) + CORE_PROTOCOL
    ).to_set.freeze
  end
end
