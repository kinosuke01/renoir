module Renoir
  class ClusterInfo
    class << self
      def node_name(host, port)
        "#{host}:#{port}"
      end
    end

    def initialize
      @slots = {}
      @nodes = {}
    end

    def load_slots(slots)
      slots.each do |s, e, master, *slaves|
        ip, port, = master
        name = add_node(ip, port)
        (s..e).each do |slot|
          set_slot(slot, name)
        end
      end
    end

    def slot_node(slot)
      @slots[slot]
    end

    def set_slot(slot, name)
      @slots[slot] = name
    end

    def node_names
      @nodes.keys
    end

    def node_info(name)
      @nodes[name]
    end

    def add_node(host, port)
      name = self.class.node_name(host, port)
      @nodes[name] = {
        host: host,
        port: port,
        name: name,
      }
      name
    end
  end
end