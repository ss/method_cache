module MethodCache
  class Proxy
    attr_reader :method_name, :opts, :args, :target

    def initialize(method_name, opts)
      @method_name = method_name
      @opts        = opts
    end

    def bind(target, args)
      self.clone.bind!(target, args)
    end
    
    def bind!(target, args)
      @target = target
      @args   = args
      @key    = nil
      self
    end

    def invalidate
      if block_given?
        # Only invalidate if the block returns true.
        value = cache[key]
        return if value and not yield(value)
      end
      cache.delete(key)
    end

    def context
      opts[:context]
    end

    def version
      dynamic_opt(:version)
    end

    def cached?
      not cache[key].nil?
    end
    
    def update
      value = block_given? ? yield(cache[key]) : target.send(method_name_without_caching, *args)
      write_to_cache(key, value)
      value
    end

    def value
      value = cache[key]
      value = nil unless valid?(:load, value)

      if value.nil?
        value = target.send(method_name_without_caching, *args)
        write_to_cache(key, value) if valid?(:save, value)
      end
          
      value = nil if value == NULL
      if clone? and value
        value.clone
      else
        value
      end
    end

    NULL = 'NULL'
    def method_with_caching
      proxy = self # Need access to the proxy in the closure.

      lambda do |*args|
        proxy.bind(self, args).value
      end
    end

    def method_name_without_caching
      @method_name_without_caching ||= begin
        base_name, punctuation = method_name.to_s.sub(/([?!=])$/, ''), $1
        "#{base_name}_without_caching#{punctuation}"
      end
    end

    def cache
      if @cache.nil?
        @cache = opts[:cache] || MethodCache.default_cache
        @cache = MemCache.pool[@cache] if @cache.kind_of?(Symbol)
      end
      @cache
    end

    def local?
      cache.kind_of?(Hash)
    end

    def clone?
      !!opts[:clone]
    end

    def key
      if @key.nil?
        arg_string = ([method_name, target] + args).collect do |arg|
          object_key(arg)
        end.join('|')
        @key = ['m', version, arg_string].compact.join('|')
      end
      @key
    end

  private

    def expiry(value)
      dynamic_opt(:expiry, value).to_i
    end

    def valid?(type, value)
      name = "#{type}_validation".to_sym
      return true unless opts[name]
      return unless value
      
      dynamic_opt(name, value)
    end

    def dynamic_opt(name, value = nil)
      if opts[name].kind_of?(Proc)
        proc = opts[name].bind(target)       
        case proc.arity
        when 0: proc.call()
        when 1: proc.call(value)
        else
          proc.call(value, *args)
        end
      else
        opts[name]
      end
    end

    def write_to_cache(key, value)
      if cache.kind_of?(Hash)
        raise 'expiry not permitted when cache is a Hash' if opts[:expiry]
        cache[key] = value
      else
        value  = value.nil? ? NULL : value
        cache.set(key, value, expiry(value))
      end
    end

    def object_key(arg)      
      return "#{class_key(arg.class)}-#{arg.string_hash}" if arg.respond_to?(:string_hash)

      case arg
      when NilClass      : 'nil'
      when TrueClass     : 'true'
      when FalseClass    : 'false'
      when Numeric       : arg.to_s
      when Symbol        : ":#{arg}"
      when String        : "'#{arg}'"
      when Class, Module : class_key(arg)
      when Hash
        '{' + arg.collect {|key, value| "#{object_key(key)}=#{object_key(value)}"}.sort.join(',') + '}'
      when Array
        '[' + arg.collect {|item| object_key(item)}.join(',') + ']'
      when defined?(ActiveRecord::Base) && ActiveRecord::Base
        "#{class_key(arg.class)}-#{arg.id}"
      else
        hash = local? ? arg.hash : Marshal.dump(arg).hash
        "#{class_key(arg.class)}-#{hash}"
      end
    end 

    def class_key(klass)
      klass.respond_to?(:version) ? "#{klass.name}_#{klass.version(context)}" : klass.name
    end
  end
end
