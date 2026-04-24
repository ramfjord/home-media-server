require 'yaml'

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
    def initialize(definition)
      @definition = definition
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
      return nil if name == 'wireguard'
      @user_id ||= `id -u #{name} 2>/dev/null`.strip
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

    def use_vpn?
      @definition['use_vpn'] == true
    end

    def sighup_reload?
      @definition['sighup_reload'] == true
    end
  end

  class Config
    attr_reader :services, :globals, :raw

    def self.load(root: '.')
      services_path = File.join(root, 'services.yml')
      local_path = File.join(root, 'config.local.yml')
      raw = YAML.load(File.read(services_path))

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

      raw['services'].each { |svc| Mediaserver.expand_vars(svc, raw) }
      services = raw['services'].map { |s| ProjectService.new(s) }

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
