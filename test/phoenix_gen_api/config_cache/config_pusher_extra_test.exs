defmodule PhoenixGenApi.ConfigPusherExtraTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigPusher
  alias PhoenixGenApi.ConfigReceiver
  alias PhoenixGenApi.Structs.{FunConfig, PushConfig}

  defp fun_config(version \\ "1.0.0") do
    %FunConfig{
      request_type: "push_test",
      service: :push_svc,
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5_000,
      mfa: {Kernel, :self, []},
      arg_types: %{},
      response_type: :sync,
      version: version
    }
  end

  defp push_config(version \\ "1.0.0") do
    ConfigPusher.from_service_config(
      :push_svc,
      [Node.self()],
      [fun_config(version)],
      config_version: version,
      module: Kernel,
      function: :self,
      args: [],
      version_module: Kernel,
      version_function: :self,
      version_args: []
    )
  end

  describe "from_service_config/4" do
    test "builds a PushConfig with all optional fields" do
      config = push_config()

      assert config.service == :push_svc
      assert config.nodes == [Node.self()]
      assert config.config_version == "1.0.0"
      assert length(config.fun_configs) == 1
      assert config.module == Kernel
      assert config.function == :self
      assert config.args == []
      assert config.version_module == Kernel
      assert config.version_function == :self
      assert config.version_args == []
    end

    test "raises when :config_version is missing" do
      assert_raise ArgumentError, ~r/requires a :config_version/, fn ->
        ConfigPusher.from_service_config(:push_svc, [Node.self()], [fun_config()], [])
      end
    end

    test "raises when :config_version is empty" do
      assert_raise ArgumentError, ~r/requires a :config_version/, fn ->
        ConfigPusher.from_service_config(:push_svc, [Node.self()], [fun_config()],
          config_version: ""
        )
      end
    end
  end

  describe "push/3 against a live ConfigReceiver" do
    setup do
      ConfigReceiver.delete_pushed_service(:push_svc)
      :ok
    end

    test "returns {:ok, :accepted} for a new version" do
      result = ConfigPusher.push(Node.self(), push_config("1.0.0"))
      assert result == {:ok, :accepted}
    end

    test "returns {:ok, :skipped, :version_matches} when pushing same version twice" do
      assert ConfigPusher.push(Node.self(), push_config("2.0.0")) == {:ok, :accepted}
      result = ConfigPusher.push(Node.self(), push_config("2.0.0"))
      assert {:ok, :skipped, reason} = result
    end

    test "returns {:ok, :accepted} when forcing an already stored version" do
      assert ConfigPusher.push(Node.self(), push_config("3.0.0")) == {:ok, :accepted}
      result = ConfigPusher.push(Node.self(), push_config("3.0.0"), force: true)
      assert result == {:ok, :accepted}
    end

    test "pushes with the configured push_token" do
      original = Application.get_env(:phoenix_gen_api, :push_token)
      Application.put_env(:phoenix_gen_api, :push_token, "secret-token")
      on_exit(fn -> Application.put_env(:phoenix_gen_api, :push_token, original) end)

      result = ConfigPusher.push(Node.self(), push_config("4.0.0"))
      assert result == {:ok, :accepted}
    end
  end

  describe "push/3 and verify/4 against an unreachable node" do
    test "push returns {:error, {:badrpc, :nodedown}}" do
      result = ConfigPusher.push(:"nonexistent_pgapi@nohost", push_config(), timeout: 100)
      assert {:error, {:badrpc, :nodedown}} = result
    end

    test "verify returns {:error, {:badrpc, :nodedown}}" do
      result = ConfigPusher.verify(:"nonexistent_pgapi@nohost", :push_svc, "1.0.0", timeout: 100)
      assert {:error, {:badrpc, :nodedown}} = result
    end
  end

  describe "verify/4 against a live ConfigReceiver" do
    setup do
      ConfigReceiver.delete_pushed_service(:push_svc)
      :ok
    end

    test "returns {:ok, :matched} when versions match" do
      assert ConfigPusher.push(Node.self(), push_config("1.1.0")) == {:ok, :accepted}
      assert ConfigPusher.verify(Node.self(), :push_svc, "1.1.0") == {:ok, :matched}
    end

    test "returns {:ok, :mismatch, stored_version} for a different version" do
      assert ConfigPusher.push(Node.self(), push_config("1.2.0")) == {:ok, :accepted}
      assert {:ok, :mismatch, "1.2.0"} = ConfigPusher.verify(Node.self(), :push_svc, "9.9.9")
    end

    test "returns {:error, :not_found} for an unknown service" do
      assert ConfigPusher.verify(Node.self(), :unknown_service, "1.0.0") == {:error, :not_found}
    end
  end

  describe "push_on_startup/3" do
    setup do
      ConfigReceiver.delete_pushed_service(:push_svc)
      :ok
    end

    test "returns the push result and registers config" do
      result = ConfigPusher.push_on_startup(Node.self(), push_config("5.0.0"), [])
      assert result == {:ok, :accepted}
      assert ConfigPusher.verify(Node.self(), :push_svc, "5.0.0") == {:ok, :matched}
    end

    test "logs skip when pushing same version twice" do
      assert ConfigPusher.push_on_startup(Node.self(), push_config("6.0.0"), []) == {:ok, :accepted}
      assert {:ok, :skipped, _} = ConfigPusher.push_on_startup(Node.self(), push_config("6.0.0"), [])
    end

    test "returns badrpc error for an unreachable node" do
      assert {:error, {:badrpc, :nodedown}} =
               ConfigPusher.push_on_startup(:"nonexistent_pgapi@nohost", push_config(),
                 timeout: 100
               )
    end
  end
end