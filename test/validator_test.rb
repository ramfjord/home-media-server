require 'minitest/autorun'
require 'mediaserver/validator'

class ValidatorTest < Minitest::Test
  def assert_invalid(services, match)
    err = assert_raises(Mediaserver::ValidationError) do
      Mediaserver::Validator.validate!(services)
    end
    assert_match match, err.message
  end

  def test_valid_minimal
    Mediaserver::Validator.validate!([{ 'name' => 'svc1' }])
  end

  def test_missing_name
    assert_invalid([{ 'desc' => 'no name' }], /missing or empty `name`/)
  end

  def test_empty_name
    assert_invalid([{ 'name' => '   ' }], /missing or empty `name`/)
  end

  def test_duplicate_names
    assert_invalid(
      [{ 'name' => 'dup' }, { 'name' => 'dup' }],
      /duplicate service name/
    )
  end

  def test_port_must_be_integer
    assert_invalid([{ 'name' => 'a', 'port' => '8080' }], /`port` must be an integer/)
  end

  def test_port_nil_ok
    Mediaserver::Validator.validate!([{ 'name' => 'a', 'port' => nil }])
  end

  def test_docker_config_must_be_mapping
    assert_invalid(
      [{ 'name' => 'a', 'docker_config' => 'image:latest' }],
      /`docker_config` must be a mapping/
    )
  end

  def test_groups_must_be_list
    assert_invalid(
      [{ 'name' => 'a', 'groups' => 'mediaserver' }],
      /`groups` must be a list/
    )
  end

  def test_use_vpn_must_be_boolean
    assert_invalid([{ 'name' => 'a', 'use_vpn' => 'yes' }], /`use_vpn` must be true or false/)
  end

  def test_sighup_reload_must_be_boolean
    assert_invalid([{ 'name' => 'a', 'sighup_reload' => 1 }], /`sighup_reload` must be true or false/)
  end

  def test_aggregates_multiple_errors
    err = assert_raises(Mediaserver::ValidationError) do
      Mediaserver::Validator.validate!([
        { 'name' => 'a', 'port' => 'x' },
        { 'name' => 'a', 'use_vpn' => 'y' },
      ])
    end
    assert_match(/port/, err.message)
    assert_match(/duplicate/, err.message)
    assert_match(/use_vpn/, err.message)
  end

  def test_real_services_yml_passes
    require 'yaml'
    path = File.expand_path('../services.yml', __dir__)
    raw = YAML.load(File.read(path))
    Mediaserver::Validator.validate!(raw['services'])
  end
end
