require 'thread'
require "renoir/cluster_info"
require "renoir/pipeline"
require "renoir/connection_adapters"
require "renoir/crc16"

module Renoir
  class Client
    REDIS_CLUSTER_HASH_SLOTS = 16_384

    DEFAULT_OPTIONS = {
      cluster_nodes: [
        ["127.0.0.1", 6379]
      ],
      max_redirection: 10,
      max_connection_error: 5,
      connect_retry_random_factor: 0.1,
      connect_retry_interval: 0.001, # 1 ms
      connection_adapter: :redis,
    }.freeze

    # @option options [Array<String, Array<String, Fixnum>, Hash{String => Fixnum}>] :cluster_nodes
    #   Array of hostnames and ports of cluster nodes. At least one node must be specified.
    #   An element could be one of: `String` (`"127.0.0.1:6379"`), `Array` (`["127.0.0.1", 6379]`) or
    #   `Hash` (`{ host: "127.0.0.1", port: 6379 }`).
    #   Defaults to `[["127.0.0.1", 6379]]`.
    # @option options [Fixnum] :max_redirection Max number of MOVED/ASK redirections. Defaults to `10`.
    # @option options [Fixnum] :max_connection_error
    #   Max number of reconnections for connection errors. Defaults to `5`.
    # @option options [Float] :connect_retry_random_factor A factor of reconnection interval. Defaults to `0.1`.
    # @option options [Float] :connect_retry_interval
    #   A base interval (seconds) of reconnection. Defaults to `0.001`, i.e., 1 ms.
    # @option options [String, Symbol] :connection_adapter
    #   Adapter name of a connection used by client. Defaults to `:redis`.
    # @option options [Logger] :logger A logger. Defaults to `nil`.
    def initialize(options)
      @connections = {}
      @cluster_info = ClusterInfo.new
      @refresh_slots = true

      options = options.map { |k, v| [k.to_sym, v] }.to_h
      @options = DEFAULT_OPTIONS.merge(options)
      @logger = @options[:logger]
      @adapter_class = ConnectionAdapters.const_get(@options[:connection_adapter].to_s.capitalize)

      cluster_nodes = @options.delete(:cluster_nodes)
      fail "the cluster_nodes option must contain at least one node" if cluster_nodes.empty?
      cluster_nodes.each do |node|
        host, port = case node
                     when Array
                       node
                     when Hash
                       [node[:host], node[:port]]
                     when String
                       node.split(":")
                     else
                       fail "invalid entry in cluster_nodes option: #{node}"
                     end
        port ||= 6379
        @cluster_info.add_node(host, port.to_i)
      end

      @connections_mutex = Mutex.new
      @refresh_slots_mutex = Mutex.new
    end

    # Call EVAL command.
    #
    # @param [Array] args arguments of EVAL passed to a connection backend
    # @yield [Object] a connection backend may yield
    # @raise [Renoir::RedirectionError] when too many redirections
    # @return the value returned by a connection backend
    def eval(*args, &block)
      call(:eval, *args, &block)
    end

    # Pipeline commands and call them with MULTI/EXEC.
    #
    # @yield [Renoir::Pipeline] A command pipeliner which has almost compatible interfaces with {Renoir::Client}.
    # @return the value returned by a connection backend
    # @raise [Renoir::RedirectionError] when too many redirections
    # @note Return value of {Renoir::Pipeline} methods is useless since "future variable" is not yet supported.
    def multi(&block)
      commands = pipeline_commands(&block)
      slot = get_slot_from_commands(commands)

      refresh_slots
      call_with_redirection(slot, [[:multi]] + commands + [[:exec]])
    end

    # Pipeline commands and call them.
    #
    # @yield [Renoir::Pipeline] A command pipeliner which has almost compatible interfaces with {Renoir::Client}.
    # @return the value returned by a connection backend
    # @raise [Renoir::RedirectionError] when too many redirections
    # @note Return value of {Renoir::Pipeline} methods is useless since "future variable" is not yet supported.
    def pipelined(&block)
      commands = pipeline_commands(&block)
      slot = get_slot_from_commands(commands)

      refresh_slots
      call_with_redirection(slot, commands)
    end

    # Call a Redis command.
    #
    # @param [Array] command a Redis command passed to a connection backend
    # @yield [Object] a connection backend may yield
    # @return the value returned by a connection backend
    # @raise [Renoir::RedirectionError] when too many redirections
    def call(*command, &block)
      slot = get_slot_from_commands([command])

      refresh_slots
      call_with_redirection(slot, [command], &block)[0]
    end

    # Close all holding connections.
    def close
      while entry = @connections.shift
        entry[1].close
      end
    end

    # Enumerate connections of cluster nodes.
    #
    # @yield [Object] an connection instance of connection backend
    # @return [Enumerable]
    def each_node
      return enum_for(:each_node) unless block_given?

      @refresh_slots = true
      refresh_slots
      @cluster_info.nodes.each do |node|
        fetch_connection(node).with_raw_connection do |conn|
          yield conn
        end
      end
    end

    # Delegated to {#call}.
    def method_missing(command, *args, &block)
      call(command, *args, &block)
    end

    def keys(matcher = '*')
      keys = []
      each_node do |node|
        keys += node.keys(matcher)
      end
      keys
    end

    def info
      results = []
      each_node do |node|
        results << node.info
      end
      results
    end

    def flushdb
      results = []
      each_node do |node|
        results << node.flushdb
      end
      results
    end

    def mget(*args)
      results = []
      args.each do |arg|
        results << get(arg)
      end
      results
    end

    def reconnect
      results = []
      each_node do |node|
        results << node.reconnect if node.respond_to?(:reconnect)
      end
      results
    end

    private

    def key_slot(key)
      s = key.index("{")
      if s
        e = key.index("}", s + 1)
        if e && e != s + 1
          key = key[s + 1..e - 1]
        end
      end
      CRC16.crc16(key) % REDIS_CLUSTER_HASH_SLOTS
    end

    def get_slot_from_commands(commands)
      keys = commands.flat_map { |command| @adapter_class.get_keys_from_command(command) }.uniq
      slots = keys.map { |key| key_slot(key) }.uniq
      fail "No way to dispatch this command to Redis Cluster." if slots.size != 1
      slots.first
    end

    def pipeline_commands(&block)
      pipeline = Pipeline.new(
        connection_adapter: @options[:connection_adapter]
      )
      yield pipeline
      pipeline.commands
    end

    def call_with_redirection(slot, commands, &block)
      nodes = @cluster_info.nodes.dup
      node = @cluster_info.slot_node(slot) || nodes.sample

      redirect_count = 0
      connect_error_count = 0
      connect_retry_count = 0
      asking = false
      loop do
        nodes.delete(node)

        conn = fetch_connection(node)
        reply = conn.call(commands, asking, &block)
        case reply
        when ConnectionAdapters::Reply::RedirectionError
          asking = reply.ask
          node = @cluster_info.add_node(reply.ip, reply.port)
          @refresh_slots ||= !asking

          redirect_count += 1
          raise RedirectionError, "Too many redirections" if @options[:max_redirection] < redirect_count
        when ConnectionAdapters::Reply::ConnectionError
          connect_error_count += 1
          raise reply.cause if @options[:max_connection_error] < connect_error_count
          if nodes.empty?
            connect_retry_count += 1
            sleep(sleep_interval(connect_retry_count))
          else
            asking = false
            node = nodes.sample
          end
        else
          return reply
        end
      end
    end

    def refresh_slots
      refresh = @refresh_slots_mutex.synchronize do
        refresh = @refresh_slots
        @refresh_slots = false
        refresh
      end
      return unless refresh

      slots = nil
      @cluster_info.nodes.each do |node|
        conn = fetch_connection(node)
        reply = conn.call([["cluster", "slots"]])
        case reply
        when ConnectionAdapters::Reply::RedirectionError
          fail "never reach here"
        when ConnectionAdapters::Reply::ConnectionError
          if @logger
            @logger.warn("CLUSTER SLOTS command failed: node_name=#{node[:name]}, message=#{reply.cause}")
          end
        else
          slots = reply[0]
          break
        end
      end
      return unless slots

      @cluster_info = ClusterInfo.new.tap do |cluster_info|
        cluster_info.load_slots(slots)
      end

      (@connections.keys - @cluster_info.node_names).each do |key|
        conn = @connections.delete(key)
        conn.close if conn
      end
    end

    def fetch_connection(node)
      name = node[:name]
      if conn = @connections[name]
        conn
      else
        @connections_mutex.synchronize do
          @connections[name] ||= @adapter_class.new(node[:host], node[:port], @options)
        end
      end
    end

    def sleep_interval(retry_count)
      factor = 1 + 2 * (rand - 0.5) * @options[:connect_retry_random_factor]
      factor * @options[:connect_retry_interval] * 2**(retry_count - 1)
    end
  end
end
