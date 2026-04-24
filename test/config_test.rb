require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'mediaserver/config'

class DeepMergeTest < Minitest::Test
  def test_scalar_override
    base = { 'a' => 1 }
    Mediaserver.deep_merge!(base, { 'a' => 2 })
    assert_equal 2, base['a']
  end

  def test_nested_hash_merge
    base = { 'a' => { 'x' => 1, 'y' => 2 } }
    Mediaserver.deep_merge!(base, { 'a' => { 'y' => 20, 'z' => 30 } })
    assert_equal({ 'x' => 1, 'y' => 20, 'z' => 30 }, base['a'])
  end

  def test_array_union
    base = { 'a' => [1, 2, 3] }
    Mediaserver.deep_merge!(base, { 'a' => [3, 4] })
    assert_equal [1, 2, 3, 4], base['a']
  end

  def test_type_mismatch_overrides
    base = { 'a' => [1, 2] }
    Mediaserver.deep_merge!(base, { 'a' => 'replaced' })
    assert_equal 'replaced', base['a']
  end

  def test_adds_new_keys
    base = { 'a' => 1 }
    Mediaserver.deep_merge!(base, { 'b' => 2 })
    assert_equal({ 'a' => 1, 'b' => 2 }, base)
  end
end

class ExpandVarsTest < Minitest::Test
  def test_string_substitution
    result = Mediaserver.expand_vars('${install_base}/config', { 'install_base' => '/opt/x' })
    assert_equal '/opt/x/config', result
  end

  def test_nested_hash
    obj = { 'a' => { 'b' => '${x}/y' } }
    Mediaserver.expand_vars(obj, { 'x' => 'VAL' })
    assert_equal 'VAL/y', obj['a']['b']
  end

  def test_array_of_strings
    obj = ['${x}', 'plain']
    Mediaserver.expand_vars(obj, { 'x' => 'V' })
    assert_equal ['V', 'plain'], obj
  end

  def test_non_string_passthrough
    assert_equal 42, Mediaserver.expand_vars(42, { 'x' => 'V' })
    assert_nil Mediaserver.expand_vars(nil, { 'x' => 'V' })
    assert_equal true, Mediaserver.expand_vars(true, { 'x' => 'V' })
  end

  def test_nil_value_in_vars_is_skipped
    result = Mediaserver.expand_vars('${x}/${y}', { 'x' => 'A', 'y' => nil })
    assert_equal 'A/${y}', result
  end
end

class ProjectServiceTest < Minitest::Test
  def test_basic_accessors
    svc = Mediaserver::ProjectService.new(
      'name' => 'foo', 'desc' => 'bar', 'port' => 1234, 'partof' => 'grp'
    )
    assert_equal 'foo', svc.name
    assert_equal 'bar', svc.desc
    assert_equal 1234, svc.port
    assert_equal 'grp', svc.partof
  end

  def test_dockerized
    assert Mediaserver::ProjectService.new('name' => 'a', 'docker_config' => {}).dockerized?
    refute Mediaserver::ProjectService.new('name' => 'a').dockerized?
  end

  def test_use_vpn_requires_true
    refute Mediaserver::ProjectService.new('name' => 'a').use_vpn?
    refute Mediaserver::ProjectService.new('name' => 'a', 'use_vpn' => false).use_vpn?
    assert Mediaserver::ProjectService.new('name' => 'a', 'use_vpn' => true).use_vpn?
  end

  def test_sighup_reload
    refute Mediaserver::ProjectService.new('name' => 'a').sighup_reload?
    assert Mediaserver::ProjectService.new('name' => 'a', 'sighup_reload' => true).sighup_reload?
  end

  def test_has_unit
    refute Mediaserver::ProjectService.new('name' => 'a').has_unit?
    assert Mediaserver::ProjectService.new('name' => 'a', 'unit' => 'plex.service').has_unit?
  end

  def test_docker_config_defaults_empty
    assert_equal({}, Mediaserver::ProjectService.new('name' => 'a').docker_config)
  end

  def test_groups_defaults_empty
    assert_equal [], Mediaserver::ProjectService.new('name' => 'a').groups
  end

  def test_wireguard_user_id_is_nil
    svc = Mediaserver::ProjectService.new('name' => 'wireguard')
    assert_nil svc.user_id
  end

  def test_indexing_passes_through
    svc = Mediaserver::ProjectService.new('name' => 'a', 'custom' => 'x')
    assert_equal 'x', svc['custom']
    assert svc.has_key?('custom')
    refute svc.has_key?('nope')
  end
end

class ConfigLoadTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(path, content)
    File.write(File.join(@dir, path), content)
  end

  def test_loads_services_and_globals
    write('services.yml', <<~YAML)
      install_base: /opt/test
      media_path: /srv/data
      hostname: example
      services:
        - name: svc1
          desc: first
          docker_config:
            image: img:latest
            volumes:
              - ${install_base}/config:/c
              - ${media_path}:/data
    YAML

    cfg = Mediaserver::Config.load(root: @dir)

    assert_equal '/opt/test', cfg.globals['install_base']
    assert_equal '/srv/data', cfg.globals['media_path']
    assert_equal 'example', cfg.globals['hostname']
    assert_equal '/opt/test/config/docker-compose.yml', cfg.globals['compose_file']
    assert_equal 1, cfg.services.length
    svc = cfg.services.first
    assert_equal 'svc1', svc.name
    assert_equal ['/opt/test/config:/c', '/srv/data:/data'], svc.docker_config['volumes']
  end

  def test_default_globals_when_missing
    write('services.yml', <<~YAML)
      services:
        - name: svc1
    YAML

    cfg = Mediaserver::Config.load(root: @dir)
    assert_equal '/opt/mediaserver', cfg.globals['install_base']
    assert_equal '/data', cfg.globals['media_path']
    assert_equal 'localhost', cfg.globals['hostname']
  end

  def test_local_override_merges_globals
    write('services.yml', <<~YAML)
      install_base: /default
      services:
        - name: svc1
    YAML
    write('config.local.yml', <<~YAML)
      install_base: /override
    YAML

    cfg = Mediaserver::Config.load(root: @dir)
    assert_equal '/override', cfg.globals['install_base']
  end

  def test_service_overrides_deep_merge
    write('services.yml', <<~YAML)
      services:
        - name: svc1
          docker_config:
            image: old:v1
            volumes:
              - /a:/a
    YAML
    write('config.local.yml', <<~YAML)
      service_overrides:
        svc1:
          docker_config:
            image: new:v2
            volumes:
              - /b:/b
    YAML

    cfg = Mediaserver::Config.load(root: @dir)
    svc = cfg.find('svc1')
    assert_equal 'new:v2', svc.docker_config['image']
    assert_equal ['/a:/a', '/b:/b'], svc.docker_config['volumes']
  end

  def test_raw_exposed
    write('services.yml', <<~YAML)
      snmp_host: box.local
      services:
        - name: svc1
    YAML

    cfg = Mediaserver::Config.load(root: @dir)
    assert_equal 'box.local', cfg.raw['snmp_host']
  end
end
