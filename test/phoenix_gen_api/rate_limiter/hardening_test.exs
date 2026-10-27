defmodule PhoenixGenApi.RateLimiter.HardeningTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.Structs.Request

  setup do
    original_admin = Application.get_env(:phoenix_gen_api, :admin_actions, [])
    original_rl = Application.get_env(:phoenix_gen_api, :rate_limiter)

    Application.put_env(:phoenix_gen_api, :admin_actions, [:update_rate_limit_config])
    Application.delete_env(:phoenix_gen_api, :rate_limiter)

    :ok = RateLimiter.set_global_limits([])
    :ok = RateLimiter.update_config(%{global_limits: [], api_limits: []})
    RateLimiter.clear()

    on_exit(fn ->
      Application.put_env(:phoenix_gen_api, :admin_actions, original_admin)
      RateLimiter.set_global_limits([])
      RateLimiter.update_config(%{global_limits: [], api_limits: []})
      RateLimiter.clear()

      if original_rl do
        Application.put_env(:phoenix_gen_api, :rate_limiter, original_rl)
      else
        Application.delete_env(:phoenix_gen_api, :rate_limiter)
      end
    end)

    :ok
  end

  defp request(user_id, overrides \\ []) do
    struct(
      %Request{
        request_id: "rl_hardening_#{System.unique_integer([:positive])}",
        user_id: user_id,
        device_id: "device_#{user_id}",
        service: "hardening_service",
        request_type: "hardening_api",
        args: %{}
      },
      overrides
    )
  end

  test "no configured limits short-circuits without a limiter round-trip" do
    parent = self()

    :telemetry.attach(
      "rl-hardening-check",
      [:phoenix_gen_api, :rate_limiter, :check],
      fn _event, _measurements, _metadata, _config -> send(parent, :checked) end,
      %{}
    )

    on_exit(fn -> :telemetry.detach("rl-hardening-check") end)

    assert :ok = RateLimiter.check_rate_limit(request("fast_path_user"))
    refute_receive :checked, 100
  end

  test "runtime limit changes take effect without restart" do
    :ok = RateLimiter.set_global_limits([%{key: :user_id, max_requests: 1, window_ms: 60_000}])

    assert :ok = RateLimiter.check_rate_limit(request("runtime_user"))
    assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request("runtime_user"))

    :ok = RateLimiter.set_global_limits([])
    assert :ok = RateLimiter.check_rate_limit(request("runtime_user"))
  end

  test "concurrent checks never admit more than the limit" do
    :ok = RateLimiter.set_global_limits([%{key: :user_id, max_requests: 20, window_ms: 60_000}])

    results =
      1..60
      |> Task.async_stream(
        fn _ -> RateLimiter.check_rate_limit(request("burst_user")) end,
        max_concurrency: 30,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 20
    assert Enum.count(results, &match?({:error, :rate_limited, _}, &1)) == 40
  end

  test "key cardinality is bounded by the configured cap" do
    Application.put_env(:phoenix_gen_api, :rate_limiter, max_rate_limit_keys: 3)

    :ok =
      RateLimiter.update_config(%{
        global_limits: [%{key: "tenant", max_requests: 1, window_ms: 60_000}]
      })

    for i <- 1..50 do
      RateLimiter.check_rate_limit(request("card_user_#{i}", args: %{"tenant" => "t#{i}"}))
    end

    keys =
      :ets.foldl(
        fn
          {{key, _ts, _uniq}}, acc -> MapSet.put(acc, key)
          _other, acc -> acc
        end,
        MapSet.new(),
        :rate_limiter_global
      )

    assert MapSet.size(keys) <= 4
  end

  test "oversized keys are hashed to a bounded size" do
    Application.put_env(:phoenix_gen_api, :rate_limiter, max_rate_limit_key_bytes: 8)

    :ok =
      RateLimiter.update_config(%{
        global_limits: [%{key: "tenant", max_requests: 1, window_ms: 60_000}]
      })

    long_key = String.duplicate("very-long-tenant-", 50)
    assert :ok = RateLimiter.check_rate_limit(request("hash_user", args: %{"tenant" => long_key}))

    keys =
      :ets.foldl(
        fn
          {{key, _ts, _uniq}}, acc -> [key | acc]
          _other, acc -> acc
        end,
        [],
        :rate_limiter_global
      )

    assert keys != []
    assert Enum.all?(keys, fn key -> is_binary(key) and byte_size(key) == 64 end)
  end

  test "an unresolved ip_address source skips the limit instead of silently applying it" do
    :ok =
      RateLimiter.set_global_limits([%{key: :ip_address, max_requests: 1, window_ms: 60_000}])

    req = request("ip_user")
    assert :ok = RateLimiter.check_rate_limit(req)
    assert :ok = RateLimiter.check_rate_limit(req)

    Application.put_env(:phoenix_gen_api, :rate_limiter, ip_address_source: :device_id)

    :ok =
      RateLimiter.set_global_limits([%{key: :ip_address, max_requests: 1, window_ms: 60_000}])

    assert :ok = RateLimiter.check_rate_limit(request("ip_user_2"))
    assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request("ip_user_2"))
  end

  test "runtime administration is gated when admin actions are configured" do
    Application.put_env(:phoenix_gen_api, :admin_actions, [:change_detail_error])

    assert {:error, :admin_action_denied} = RateLimiter.set_global_limits([])
    assert {:error, :admin_action_denied} = RateLimiter.clear()

    instance = :rate_limiter_instance_0

    assert {:error, :admin_action_denied} =
             GenServer.call(instance, {:set_global_limits, []})

    Application.put_env(:phoenix_gen_api, :admin_actions, [:update_rate_limit_config])
    assert :ok = RateLimiter.set_global_limits([])
  end

  test "sweeping keeps timestamps that are still inside the runtime window" do
    :ok =
      RateLimiter.set_global_limits([%{key: :user_id, max_requests: 2, window_ms: 120_000}])

    assert :ok = RateLimiter.check_rate_limit(request("window_user"))
    assert :ok = RateLimiter.check_rate_limit(request("window_user"))

    # Replace the window at runtime and force several sweeps.
    :ok =
      RateLimiter.set_global_limits([%{key: :user_id, max_requests: 2, window_ms: 240_000}])

    Enum.each(1..5, fn _ -> send(:rate_limiter_instance_0, :cleanup) end)
    Process.sleep(100)

    assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request("window_user"))
    assert %{instance_count: _} = RateLimiter.status()
  end
end
