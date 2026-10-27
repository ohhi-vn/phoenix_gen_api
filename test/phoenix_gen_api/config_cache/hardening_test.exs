defmodule PhoenixGenApi.ConfigCache.HardeningTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.{ConfigDb, ConfigFailed, ConfigPuller, ConfigReceiver, Executor}
  alias PhoenixGenApi.Structs.{FunConfig, PushConfig, Request, ServiceConfig}

  def ok_fun, do: {:ok, :latest}
  def old_fun, do: {:ok, :old}

  setup do
    original = %{
      admin: Application.get_env(:phoenix_gen_api, :admin_actions),
      binding: Application.get_env(:phoenix_gen_api, :config_source_binding),
      downgrade: Application.get_env(:phoenix_gen_api, :reject_config_downgrades),
      cap: Application.get_env(:phoenix_gen_api, :max_configs_per_service),
      allow_version: Application.get_env(:phoenix_gen_api, :allow_client_version),
      protect_puller: Application.get_env(:phoenix_gen_api, :protect_config_puller),
      node_allowlist: Application.get_env(:phoenix_gen_api, :pull_node_allowlist)
    }

    :ets.delete_all_objects(ConfigDb)

    on_exit(fn ->
      restore(:admin_actions, original.admin)
      restore(:config_source_binding, original.binding)
      restore(:reject_config_downgrades, original.downgrade)
      restore(:max_configs_per_service, original.cap)
      restore(:allow_client_version, original.allow_version)
      restore(:protect_config_puller, original.protect_puller)
      restore(:pull_node_allowlist, original.node_allowlist)
      :ets.delete_all_objects(ConfigDb)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:phoenix_gen_api, key)
  defp restore(key, value), do: Application.put_env(:phoenix_gen_api, key, value)

  defp fun_config(overrides \\ %{}) do
    struct(
      %FunConfig{
        request_type: "hard_test",
        service: "hard_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.0.0",
        check_permission: false,
        request_info: false
      },
      overrides
    )
  end

  defp push_config(overrides \\ %{}) do
    struct(
      PushConfig,
      Map.merge(
        %{
          service: "hard_service",
          nodes: [Node.self()],
          config_version: "1.0.0",
          fun_configs: [fun_config()]
        },
        Map.new(overrides)
      )
    )
  end

  test "update/1 validates the same MFA rules as add/1" do
    config = fun_config(%{mfa: {:os, :cmd, []}})

    assert {:error, :invalid_config} = ConfigDb.update(config)

    assert {:error, :not_found} =
             ConfigDb.get(config.service, config.request_type, config.version)
  end

  test "hooks, node resolvers, permission callbacks, and encoders are validated before storage" do
    variants = [
      %{before_execute: {:os, :cmd, []}},
      %{after_execute: {:os, :cmd, []}},
      %{permission_callback: {:os, :cmd, []}},
      %{result_encoder: {:os, :cmd, []}},
      %{nodes: {:os, :cmd, []}}
    ]

    Enum.each(variants, fn overrides ->
      config = fun_config(Map.put(overrides, :request_type, "hard_#{inspect(overrides)}"))
      assert {:error, {:mfa_not_allowed, _mfa}} = ConfigDb.add(config)
    end)
  end

  test "rejected writes preserve the previously registered configuration" do
    good = fun_config(%{request_type: "hard_preserve"})
    assert :ok = ConfigDb.add(good)

    bad = fun_config(%{request_type: "hard_preserve", mfa: {:os, :cmd, []}})
    assert {:error, {:mfa_not_allowed, _mfa}} = ConfigDb.add(bad)

    assert {:ok, %FunConfig{mfa: {String, :upcase, []}}} =
             ConfigDb.get("hard_service", "hard_preserve", "1.0.0")
  end

  test "push is denied when admin actions are configured without push_config" do
    Application.put_env(:phoenix_gen_api, :admin_actions, [:change_detail_error])

    assert {:error, :admin_action_denied} = ConfigReceiver.push(push_config())
  end

  test "push source binding rejects an origin that is not in the pushed nodes" do
    Application.put_env(:phoenix_gen_api, :config_source_binding, true)

    config =
      push_config(%{
        nodes: [:attacker@elsewhere],
        fun_configs: [fun_config(%{nodes: [:attacker@elsewhere]})]
      })

    assert {:error, :source_not_allowed} = ConfigReceiver.push(config)
  end

  test "downgrade rejection rejects an older version and keeps the stored one" do
    Application.put_env(:phoenix_gen_api, :reject_config_downgrades, true)

    v2 = push_config(%{config_version: "2.0.0", service: "hard_downgrade"})
    v2 = %{v2 | fun_configs: [fun_config(%{service: "hard_downgrade", version: "2.0.0"})]}
    assert {:ok, :accepted} = ConfigReceiver.push(v2)

    v1 = push_config(%{config_version: "1.0.0", service: "hard_downgrade"})
    v1 = %{v1 | fun_configs: [fun_config(%{service: "hard_downgrade", version: "1.0.0"})]}

    assert {:error, :version_downgrade} = ConfigReceiver.push(v1)
  end

  test "stored versions are capped per service and request type" do
    Application.put_env(:phoenix_gen_api, :max_configs_per_service, 2)

    for version <- ["1.0.0", "2.0.0", "3.0.0"] do
      config = fun_config(%{request_type: "hard_cap", version: version})
      assert :ok = ConfigDb.add(config)
    end

    versions =
      :ets.match(ConfigDb, {{"hard_service", "hard_cap", :"$1"}, :_})
      |> Enum.map(fn [version] -> version end)
      |> Enum.sort()

    assert versions == ["2.0.0", "3.0.0"]
  end

  test "client version selection can be disabled" do
    old =
      fun_config(%{
        request_type: "hard_version",
        version: "1.0.0",
        mfa: {__MODULE__, :old_fun, []}
      })

    new =
      fun_config(%{
        request_type: "hard_version",
        version: "2.0.0",
        mfa: {__MODULE__, :ok_fun, []}
      })

    assert :ok = ConfigDb.add(old)
    assert :ok = ConfigDb.add(new)

    request = %Request{
      request_id: "hard_version_req",
      request_type: "hard_version",
      service: "hard_service",
      user_id: "u1",
      device_id: "d1",
      version: "1.0.0",
      args: %{}
    }

    assert %{success: true, result: :old} = Executor.execute!(request)

    Application.put_env(:phoenix_gen_api, :allow_client_version, false)

    assert %{success: true, result: :latest} = Executor.execute!(request)
  end

  test "puller registration is gated and node-allowlisted when configured" do
    Application.put_env(:phoenix_gen_api, :protect_config_puller, true)
    Application.put_env(:phoenix_gen_api, :admin_actions, [])

    service = %ServiceConfig{
      service: "hard_pull_gate",
      nodes: [Node.self()],
      module: String,
      function: :upcase,
      args: []
    }

    assert {:error, :admin_action_denied} = ConfigPuller.add([service])

    Application.put_env(:phoenix_gen_api, :admin_actions, [:push_config])
    Application.put_env(:phoenix_gen_api, :pull_node_allowlist, [Node.self()])

    disallowed = %{service | nodes: [:other@host]}
    assert {:error, {:node_not_allowed, _nodes}} = ConfigPuller.add([disallowed])
  end

  test "failed-config cleanup removes expired records" do
    now = System.system_time(:millisecond)

    :ets.insert(
      :phoenix_gen_api_config_failed,
      {:hard_expired,
       %{
         id: :hard_expired,
         service: "hard_service",
         request_type: "hard_expired",
         version: "1.0.0",
         source: :push,
         node: nil,
         reason: ["expired"],
         config: %{},
         inserted_at_ms: now - 10,
         expires_at_ms: now - 5
       }}
    )

    assert ConfigFailed.cleanup() >= 1
    refute :ets.member(:phoenix_gen_api_config_failed, :hard_expired)
  end
end
