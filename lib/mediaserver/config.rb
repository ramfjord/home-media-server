require 'yaml'
require_relative 'validator'

module Mediaserver
  DEFAULT_GLOBALS = {
    'install_base' => '/opt/mediaserver',
    'media_path' => '/data',
    'hostname' => 'localhost',
  }.freeze

  def self.get_group_id(group_name)
    `getent group #{group_name} 2>/dev/null | cut -d: -f3`.strip
  end

  def self.deep_merge!(base, overrides)
    overrides.each do |key, value|
      if value.is_a?(Hash) && base[key].is_a?(Hash)
        deep_merge!(base[key], value)
      elsif value.is_a?(Array) && base[key].is_a?(Array)
        base[key] = (base[key] | value)
      else
        base[key] = value
      end
    end
    base
  end

  def self.expand_vars(obj, vars)
    case obj
    when Hash
      obj.each { |k, v| obj[k] = expand_vars(v, vars) }
    when Array
      obj.map! { |v| expand_vars(v, vars) }
    when String
      result = obj
      vars.each { |k, v| result = result.gsub("${#{k}}", v.to_s) if v }
      result
    else
      obj
    end
  end

  class ProjectService
    def initialize(definition, install_base = '/opt/mediaserver')
      @definition = definition
      @install_base = install_base
    end

    def name
      @definition['name']
    end

    def dockerized?
      @definition.key?('docker_config')
    end

    def unit
      @definition['unit']
    end

    def user_id
      uid = @definition['user_id']
      return nil if uid == false
      return uid.to_s if uid
      raise "Service '#{name}' has no user_id defined. Add `user_id: <number>` to services/#{name}/service.yml or to config.local.yml's service_overrides:#{name}:user_id (or `user_id: false` to opt out of having a user: in compose)." if dockerized?
      nil
    end

    def partof
      @definition['partof']
    end

    def desc
      @definition['desc']
    end

    def port
      @definition['port']
    end

    def healthz
      @definition['healthz']
    end

    def docker_config
      @definition['docker_config'] || {}
    end

    def groups
      @definition['groups'] || []
    end

    def group_ids
      groups.map { |g| Mediaserver.get_group_id(g) }.compact
    end

    def has_unit?
      @definition.key?('unit')
    end

    def [](key)
      @definition[key]
    end

    def has_key?(key)
      @definition.has_key?(key)
    end

    def source_dir
      "services/#{name}"
    end

    def use_vpn?
      @definition['use_vpn'] == true
    end

    def sighup_reload?
      @definition['sighup_reload'] == true
    end

    def compose_file
      "#{@install_base}/config/#{name}/docker-compose.yml"
    end
  end

  class Config
    attr_reader :services, :globals, :raw

    def self.load(root: '.')
      globals_path = File.join(root, 'globals.yml')
      local_path = File.join(root, 'config.local.yml')
      services_glob = File.join(root, 'services', '*', 'service.yml')

      globals_raw = File.exist?(globals_path) ? (YAML.load(File.read(globals_path)) || {}) : {}
      service_defs = Dir[services_glob].sort.map do |path|
        YAML.load(File.read(path)) or raise "empty service file: #{path}"
      end
      # Stable sort by optional `order` field; missing order goes to the end.
      service_defs = service_defs.sort_by.with_index { |s, i| [s['order'] || Float::INFINITY, i] }

      raw = globals_raw.merge('services' => service_defs)

      if File.exist?(local_path)
        local = YAML.load(File.read(local_path))
        if local
          service_overrides = local.delete('service_overrides') || {}
          raw.merge!(local)
          service_overrides.each do |svc_name, overrides|
            svc_def = raw['services'].find { |s| s['name'] == svc_name }
            next unless svc_def
            Mediaserver.deep_merge!(svc_def, overrides)
          end
        end
      end

      globals = DEFAULT_GLOBALS.merge(raw.reject { |k, _| k == 'services' })
      globals['install_base'] = raw['install_base'] || DEFAULT_GLOBALS['install_base']
      globals['media_path'] = raw['media_path'] || DEFAULT_GLOBALS['media_path']
      globals['hostname'] = raw['hostname'] || DEFAULT_GLOBALS['hostname']
      globals['compose_file'] = "#{globals['install_base']}/config/docker-compose.yml"

      Validator.validate!(raw['services'])
      raw['services'].each { |svc| Mediaserver.expand_vars(svc, raw) }
      install_base = globals['install_base']
      services = raw['services'].map { |s| ProjectService.new(s, install_base) }

      new(services: services, globals: globals, raw: raw)
    end

    def initialize(services:, globals:, raw: nil)
      @services = services
      @globals = globals
      @raw = raw
    end

    def find(name)
      @services.find { |s| s.name == name }
    end
  end
end
