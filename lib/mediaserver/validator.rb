module Mediaserver
  class ValidationError < StandardError; end

  class Validator
    def self.validate!(services)
      errors = []
      names = []

      services.each_with_index do |svc_def, idx|
        prefix = "services[#{idx}]"
        name = svc_def['name']

        if name.nil? || !name.is_a?(String) || name.strip.empty?
          errors << "#{prefix}: missing or empty `name`"
          next
        end
        prefix = "service `#{name}`"

        if names.include?(name)
          errors << "#{prefix}: duplicate service name"
        end
        names << name

        port = svc_def['port']
        unless port.nil? || port.is_a?(Integer)
          errors << "#{prefix}: `port` must be an integer (got #{port.class}: #{port.inspect})"
        end

        if svc_def.key?('docker_config') && !svc_def['docker_config'].is_a?(Hash)
          errors << "#{prefix}: `docker_config` must be a mapping"
        end

        if svc_def.key?('groups') && !svc_def['groups'].is_a?(Array)
          errors << "#{prefix}: `groups` must be a list"
        end

        %w[use_vpn sighup_reload].each do |flag|
          next unless svc_def.key?(flag)
          v = svc_def[flag]
          unless v == true || v == false
            errors << "#{prefix}: `#{flag}` must be true or false (got #{v.inspect})"
          end
        end
      end

      unless errors.empty?
        raise ValidationError, "invalid service definitions:\n  - #{errors.join("\n  - ")}"
      end
    end
  end
end
