# frozen_string_literal: true

# Copyright 2018 Tristan Robert

# This file is part of ForemanProxmox.

# ForemanProxmox is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# ForemanProxmox is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with ForemanProxmox. If not, see <http://www.gnu.org/licenses/>.

require 'fog/proxmox'

module ForemanProxmox
  class Proxmox < ComputeResource
    validates :url, :format => { :with => URI::DEFAULT_PARSER.make_regexp }, :presence => true
    validates :user, :format => { :with => /(\w+)[@]{1}(\w+)/ }, :presence => true
    validates :password, :presence => true

    def provided_attributes
      super.merge(
        :mac  => :mac
      )
    end
    
    def self.provider_friendly_name
      "Proxmox"
    end

    def capabilities
      [:build]
    end

    def find_vm_by_uuid(uuid)
      node.servers.get(uuid)
    rescue Fog::Errors::Error => e
      Foreman::Logging.exception("Failed retrieving proxmox vm by vmid #{uuid}", e)
      raise(ActiveRecord::RecordNotFound) if e.message.include?('HANDLE_INVALID')
      raise(ActiveRecord::RecordNotFound) if e.message.include?('VM.get_record: ["SESSION_INVALID"')
      raise e
    end

    def self.model_name
      ComputeResource.model_name
    end

    def credentials_valid?
      errors[:url].empty? && errors[:user].empty? && errors[:user].include?('@') && errors[:password].empty? && node
    end

    def test_connection(options = {})
      super
      credentials_valid?
    rescue StandardError => e
      begin
        disconnect
      rescue StandardError
        nil
      end
      errors[:base] << e.message
    end

    def nodes
      nodes = client.nodes.all
      nodes.sort_by(&:node)
    end

    def pools
      pools = identity_client.pools.all
      pools.sort_by(&:poolid)
    end

    def storages
      storages = node.storages.all
      storages.sort_by(&:storage)
    end

    def associated_host(vm)
      associate_by('node', vm.node)
    end

    def new_vm(attr = {})
      test_connection
      node.servers.new(vm_instance_defaults.merge(attr.to_hash.deep_symbolize_keys)) if errors.empty?
    end

    def create_vm(args = {})
      raise ::Foreman::Exception.new N_("invalid vmid") unless node.servers.id_valid?(args[:vmid])
      node = get_cluster_node args
      logger.debug("create_vm(): #{args}")
      node.servers.create(parse_vm(args))
      vm = node.servers.get(args[:vmid])
      vm
    rescue => e
      logger.warn "failed to create vm: #{e}"
      destroy_vm vm.id if vm
      raise e
    end

    def parse_vm(args)
      config = args['config']
      volumes = parse_volume(args['volumes'])
      cpu_a = ['cpu_type','spectre','pcid','vcpus','cpulimit','cpuunits','cores','sockets','numa']
      cpu = parse_cpu(config.select { |key,_value| cpu_a.include? key })
      memory_a = ['memory','min_memory','balloon','shares']
      memory = parse_memory(config.select { |key,_value| memory_a.include? key })
      general_a = ['node','config','volumes','interfaces_attributes','firmware_type','provision_method']
      logger.debug("general_a: #{general_a}")
      args.delete_if { |key,_value| general_a.include? key }
      config.delete_if { |key,_value| cpu_a.include? key }
      config.delete_if { |key,_value| memory_a.include? key }
      config.delete_if { |_key,value| value.empty? }
      config.each { |_key,value| value = value.to_i }
      logger.debug("parse_config(): #{config}")
      parsed_vm = args.merge(config).merge(volumes).merge(cpu).merge(memory)
      logger.debug("parse_vm(): #{parsed_vm}")
      parsed_vm
    end

    def parse_memory(args)
      memory = {memory: args['memory'].to_i}
      ballooned = args['balloon'].to_i == 1
      if ballooned
        memory.store(:shares,args['shares'].to_i)
        memory.store(:balloon,args['min_memory'].to_i)
      else
        memory.store(:balloon,args['balloon'].to_i)
      end
      logger.debug("parse_memory(): #{memory}")
      memory
    end

    def parse_cpu(args)
      cpu = "cputype=#{args['cpu_type']}"
      spectre = args['spectre'].to_i == 1
      pcid = args['pcid'].to_i == 1
      cpu += ",flags=" if spectre || pcid
      cpu += "+spec-ctrl" if spectre
      cpu += ";" if spectre && pcid
      cpu += "+pcid" if pcid      
      args.delete_if { |key,_value| ['cpu_type','spectre','pcid'].include? key }
      args.delete_if { |_key,value| value.empty? }
      args.each { |_key,value| value = value.to_i }
      parsed_cpu = { cpu: cpu }.merge(args)
      logger.debug("parse_cpu(): #{parsed_cpu}")
      parsed_cpu
    end

    def parse_volume(args)
      disk = {}
      id = "#{args['bus']}#{args['device']}"
      delete = args['_delete'].to_i == 1
      if delete
        logger.debug("parse_volumes(): delete id=#{id}")
        disk.store(:delete, id)
        disk
      else
        disk.store(:id, id)
        disk.store(:storage, "#{args['storage']}")
        disk.store(:size, "#{args['size']}")
        options = args.reject { |key,_value| ['bus','device','storage','size','_delete'].include? key}
        logger.debug("parse_volume(): add disk=#{disk}, options=#{options}")
        Fog::Proxmox::Disk.flatten(disk,Fog::Proxmox::Hash.stringify(options))
      end 
    end

    def next_vmid
      node.servers.next_id
    end

    def new_volume(attr = {})
      storages = node.storages.list_by_content_type 'images'
      storage = storages.first
      storage.volumes.new attr
    rescue => e
      logger.warn "failed to initialize volume: #{e}"
      raise e
    end

    def new_volume_errors
      []
    end

    protected

    def fog_credentials
      { pve_url: url,
        pve_username: user,
        pve_password: password,
        connection_options: { disable_proxy: true, ssl_verify_peer: false } } # dev tests only
    end

    def client
      @client ||= ::Fog::Compute::Proxmox.new(fog_credentials)
    end

    def identity_client
      @identity_client ||= ::Fog::Identity::Proxmox.new(fog_credentials)
    end

    def disconnect
      client.terminate if @client
      @client = nil
    end

    def vm_instance_defaults
      super.merge(vmid: next_vmid, node: node)
    end

    private

    def node
      get_cluster_node
    end

    def get_cluster_node(args = {})
      args.empty? ? client.nodes.first : client.nodes.find_by_id(args[:node])
    end

  end
end