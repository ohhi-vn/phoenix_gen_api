defmodule PhoenixGenApi.Helpers.SharedTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Helpers.Shared
  alias PhoenixGenApi.Structs.FunConfig

  describe "same_service?/2" do
    test "returns true for identical atoms" do
      assert Shared.same_service?(:my_service, :my_service) == true
    end

    test "returns true for identical strings" do
      assert Shared.same_service?("my_service", "my_service") == true
    end

    test "returns true for atom and equivalent string" do
      assert Shared.same_service?(:my_service, "my_service") == true
    end

    test "returns true for string and equivalent atom" do
      assert Shared.same_service?("my_service", :my_service) == true
    end

    test "returns false for different atoms" do
      assert Shared.same_service?(:service_a, :service_b) == false
    end

    test "returns false for different strings" do
      assert Shared.same_service?("service_a", "service_b") == false
    end

    test "returns false for atom and different string" do
      assert Shared.same_service?(:my_service, "other_service") == false
    end

    test "returns false for non-string non-atom arguments" do
      assert Shared.same_service?(123, :my_service) == false
      assert Shared.same_service?(:my_service, nil) == false
      assert Shared.same_service?(nil, nil) == false
      assert Shared.same_service?([], "list") == false
    end
  end

  describe "enforce_service_name/2" do
    test "returns config unchanged when service names match (atoms)" do
      config = %FunConfig{request_type: "test", service: :my_service}
      result = Shared.enforce_service_name(config, :my_service)
      assert result == config
    end

    test "returns config unchanged when service names match (strings)" do
      config = %FunConfig{request_type: "test", service: "my_service"}
      result = Shared.enforce_service_name(config, "my_service")
      assert result == config
    end

    test "returns config unchanged when atom matches string" do
      config = %FunConfig{request_type: "test", service: :my_service}
      result = Shared.enforce_service_name(config, "my_service")
      assert result == config
    end

    test "overwrites service name when mismatched" do
      config = %FunConfig{request_type: "test", service: :wrong_service}
      result = Shared.enforce_service_name(config, :correct_service)
      assert result.service == :correct_service
    end

    test "overwrites service name when types differ (atom vs string)" do
      config = %FunConfig{request_type: "test", service: "old_service"}
      result = Shared.enforce_service_name(config, :new_service)
      assert result.service == :new_service
    end

    test "preserves other fields when overwriting" do
      config = %FunConfig{
        request_type: "test",
        service: :wrong,
        timeout: 5000,
        nodes: :local
      }

      result = Shared.enforce_service_name(config, :correct)
      assert result.service == :correct
      assert result.request_type == "test"
      assert result.timeout == 5000
      assert result.nodes == :local
    end
  end

  describe "ensure_version/1" do
    test "returns config with valid version unchanged" do
      config = %FunConfig{request_type: "test", version: "1.2.3"}
      result = Shared.ensure_version(config)
      assert result.version == "1.2.3"
    end

    test "sets version to nil when it's nil" do
      config = %FunConfig{request_type: "test", version: nil}
      result = Shared.ensure_version(config)
      assert result.version == nil
    end

    test "sets version to nil when it's empty string" do
      config = %FunConfig{request_type: "test", version: ""}
      result = Shared.ensure_version(config)
      assert result.version == nil
    end

    test "sets version to nil for reserved sentinel 0.0.0" do
      config = %FunConfig{request_type: "test", version: "0.0.0"}
      result = Shared.ensure_version(config)
      assert result.version == nil
    end

    test "preserves valid semver versions" do
      for version <- ["1.0.0", "2.3.4", "10.20.30", "0.1.0", "1.0.0-beta"] do
        config = %FunConfig{request_type: "test", version: version}
        result = Shared.ensure_version(config)
        assert result.version == version
      end
    end

    test "handles config without version key (old format)" do
      config = %FunConfig{request_type: "test"}
      result = Shared.ensure_version(config)
      assert result.version == nil
    end

    test "sets version to nil for non-binary values" do
      config = %FunConfig{request_type: "test", version: :some_atom}
      result = Shared.ensure_version(config)
      assert result.version == nil
    end
  end

  describe "valid_node?/1" do
    test "returns true for atom node" do
      assert Shared.valid_node?(:node1@host)
      assert Shared.valid_node?(:any@where)
    end

    test "returns true for binary string node" do
      assert Shared.valid_node?("node1@host")
      assert Shared.valid_node?("any@where")
    end

    test "returns false for integer" do
      refute Shared.valid_node?(123)
    end

    test "returns true for nil (nil is an atom in Elixir)" do
      # In Elixir, nil is an atom, so valid_node?(:nil) returns true
      # This documents the current behavior
      assert Shared.valid_node?(nil)
    end

    test "returns false for list" do
      refute Shared.valid_node?([:node1@host])
    end

    test "returns false for map" do
      refute Shared.valid_node?(%{name: "node1"})
    end

    test "returns true for empty string (binary)" do
      # Empty string is still a binary, so it returns true per spec
      assert Shared.valid_node?("")
    end
  end

  describe "validate_nodes/1" do
    test "filters out invalid entries from a list" do
      # Note: nil is an atom in Elixir, so it passes valid_node?
      result = Shared.validate_nodes([:node1@host, "node2@host", 123, :node3@host])
      assert result == [:node1@host, "node2@host", :node3@host]
    end

    test "returns empty list when all entries are invalid" do
      # Note: nil is an atom, so we use truly invalid types
      result = Shared.validate_nodes([123, [], %{}, {}])
      assert result == []
    end

    test "returns empty list for empty input" do
      result = Shared.validate_nodes([])
      assert result == []
    end

    test "returns empty list for non-list input" do
      result = Shared.validate_nodes("not a list")
      assert result == []
    end

    test "returns empty list for nil input" do
      result = Shared.validate_nodes(nil)
      assert result == []
    end

    test "preserves all valid atom nodes" do
      nodes = [:node1@host, :node2@host, :node3@host]
      assert Shared.validate_nodes(nodes) == nodes
    end

    test "preserves all valid string nodes" do
      nodes = ["node1@host", "node2@host"]
      assert Shared.validate_nodes(nodes) == nodes
    end

    test "preserves order of valid nodes" do
      nodes = [:node3@host, :node1@host, :node2@host]
      assert Shared.validate_nodes(nodes) == [:node3@host, :node1@host, :node2@host]
    end
  end
end
