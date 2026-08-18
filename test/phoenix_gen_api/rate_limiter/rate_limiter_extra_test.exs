defmodule PhoenixGenApi.RateLimiterExtraTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.Structs.Request

  setup do
    original_admin_actions = Application.get_env(:phoenix_gen_api, :admin_actions, [])

    Application.put_env(:phoenix_gen_api, :admin_actions, [
      :update_rate_limit_config,
      :change_detail_error,
      :push_config
    ])

    RateLimiter.update_config(%{global_limits: [], api_limits: []})
    RateLimiter.clear()

    on_exit(fn ->
      Application.put_env(:phoenix_gen_api, :admin_actions, original_admin_actions)
    end)

    on_exit(fn ->
      RateLimiter.update_config(%{global_limits: [], api_limits: []})
      RateLimiter.clear()
    end)

    :ok
  end

  defp with_rate_limiter_env(env, fun) do
    original = Application.get_env(:phoenix_gen_api, :rate_limiter)

    Application.put_env(:phoenix_gen_api, :rate_limiter, env)

    try do
      fun.()
    after
      if original do
        Application.put_env(:phoenix_gen_api, :rate_limiter, original)
      else
        Application.delete_env(:phoenix_gen_api, :rate_limiter)
      end
    end
  end

  defp request(unique, user_id) do
    %Request{
      request_id: "coverage_rl_#{unique}",
      user_id: user_id,
      service: "coverage_service",
      request_type: "coverage_api"
    }
  end

  describe "attach_telemetry/3" do
    test "attaches and detaches telemetry handlers" do
      handler = fn _event, _measurements, _metadata, _config -> :ok end
      assert :ok = RateLimiter.attach_telemetry("coverage-rl-handler", handler)
      assert :ok = RateLimiter.detach_telemetry("coverage-rl-handler")
      assert :ok = RateLimiter.detach_telemetry("coverage-rl-handler")
    end
  end

  describe "start_link/0" do
    test "returns already_started since the limiter is running" do
      assert {:error, {:already_started, _pid}} = RateLimiter.start_link()
    end
  end

  describe "routing strategy and instance count config" do
    test "get_instance_count handles :auto, integer, and invalid values" do
      with_rate_limiter_env(%{instance_count: :auto}, fn ->
        assert RateLimiter.instance_count() > 0
      end)

      with_rate_limiter_env(%{instance_count: 3}, fn ->
        assert RateLimiter.instance_count() == 3
      end)

      with_rate_limiter_env(%{instance_count: :bogus}, fn ->
        assert RateLimiter.instance_count() > 0
      end)
    end

    test "get_routing_strategy handles :random and invalid values" do
      with_rate_limiter_env(%{routing_strategy: :random}, fn ->
        assert RateLimiter.routing_strategy() == :random
      end)

      with_rate_limiter_env(%{routing_strategy: :bogus}, fn ->
        assert RateLimiter.routing_strategy() == :hash
      end)
    end

    test "check_rate_limit uses :random routing when configured" do
      with_rate_limiter_env(%{routing_strategy: :random}, fn ->
        RateLimiter.update_config(%{
          global_limits: [%{key: :user_id, max_requests: 100, window_ms: 60_000}],
          api_limits: []
        })

        assert :ok == RateLimiter.check_rate_limit(request(1, "random_user"))
        assert :ok == RateLimiter.check_rate_limit("random_user", :global, :user_id)
      end)
    end
  end

  describe "fail-open and fail-closed on errors" do
    test "fails open when the instance call fails" do
      with_rate_limiter_env(%{timeout: :bogus, fail_open: true}, fn ->
        assert :ok == RateLimiter.check_rate_limit(request(2, "failopen_user"))
      end)
    end

    test "fails closed when the instance call fails" do
      with_rate_limiter_env(%{timeout: :bogus, fail_open: false}, fn ->
        assert {:error, :rate_limiter_error, %{message: _}} =
                 RateLimiter.check_rate_limit(request(3, "failclosed_user"))
      end)
    end
  end

  describe "status/0" do
    test "returns status for all instances" do
      status = RateLimiter.status()
      assert status.status == :ok
      assert status.instance_count > 0
      assert length(status.instances) == status.instance_count
      assert hd(status.instances).status == :ok
    end
  end

  describe "admin action gating for update_config/1" do
    test "returns denied when update_rate_limit_config is not allowed" do
      Application.put_env(:phoenix_gen_api, :admin_actions, [])

      assert {:error, :admin_action_denied} =
               RateLimiter.update_config(%{global_limits: []})
    end

    test "returns denied when change_detail_error is not allowed" do
      Application.put_env(:phoenix_gen_api, :admin_actions, [:update_rate_limit_config])

      assert {:error, :admin_action_denied} =
               RateLimiter.update_config(%{detail_error: true})
    end

    test "allows updates when all required admin actions are allowed" do
      Application.put_env(:phoenix_gen_api, :admin_actions, [
        :update_rate_limit_config,
        :change_detail_error
      ])

      assert :ok == RateLimiter.update_config(%{detail_error: true, global_limits: []})
    end
  end

  describe "add/remove global limits" do
    test "adds and replaces global limits" do
      RateLimiter.add_global_limit(%{key: :user_id, max_requests: 5, window_ms: 10_000})
      config = RateLimiter.get_configured_limits()
      assert length(config.global) == 1

      RateLimiter.add_global_limit(%{key: :user_id, max_requests: 9, window_ms: 10_000})
      config = RateLimiter.get_configured_limits()
      assert length(config.global) == 1
      assert hd(config.global).max_requests == 9
    end

    test "removes a global limit" do
      RateLimiter.add_global_limit(%{key: :device_id, max_requests: 5, window_ms: 10_000})
      RateLimiter.add_global_limit(%{key: :user_id, max_requests: 5, window_ms: 10_000})
      assert length(RateLimiter.get_configured_limits().global) == 2

      assert :ok == RateLimiter.remove_global_limit(:device_id)
      assert length(RateLimiter.get_configured_limits().global) == 1
    end
  end

  describe "key types" do
    test "rate limits by device_id, ip_address, and custom args keys" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :device_id, max_requests: 1, window_ms: 10_000},
          %{key: :ip_address, max_requests: 1, window_ms: 10_000},
          %{key: "plan_tier", max_requests: 1, window_ms: 10_000},
          %{key: :some_unknown_key, max_requests: 1, window_ms: 10_000}
        ],
        api_limits: []
      })

      device_req = %{request(4, "user_a") | device_id: "device_a"}
      assert :ok == RateLimiter.check_rate_limit(device_req)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(device_req)

      ip_req = Map.put(request(5, "user_b"), :ip_address, "10.0.0.1")
      assert :ok == RateLimiter.check_rate_limit(ip_req)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(ip_req)

      custom_req = %{request(6, "user_c") | args: %{"plan_tier" => "gold"}}
      assert :ok == RateLimiter.check_rate_limit(custom_req)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(custom_req)

      # unknown key type -> nil value -> always allowed
      assert :ok == RateLimiter.check_rate_limit(request(7, "user_d"))
      assert :ok == RateLimiter.check_rate_limit(request(7, "user_d"))
    end
  end

  describe "direct reset and status for API scope" do
    test "resets API-scoped limits and reports status" do
      RateLimiter.update_config(%{
        global_limits: [],
        api_limits: [
          %{
            service: "svc",
            request_type: "api",
            key: :user_id,
            max_requests: 2,
            window_ms: 10_000
          }
        ]
      })

      scope = {"svc", "api"}

      assert :ok == RateLimiter.check_rate_limit("api_user", scope, :user_id)
      assert :ok == RateLimiter.check_rate_limit("api_user", scope, :user_id)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit("api_user", scope, :user_id)

      status = RateLimiter.get_rate_limit_status("api_user", scope, :user_id)
      assert is_list(status)
      assert length(status) == 1

      assert :ok == RateLimiter.reset_rate_limit("api_user", scope, :user_id)
      assert :ok == RateLimiter.check_rate_limit("api_user", scope, :user_id)
    end
  end

  describe "update_config/1 with empty config" do
    test "falls back to catch-all clauses" do
      assert :ok == RateLimiter.update_config(%{})
    end
  end

  describe "handle_info messages" do
    test "ignores unknown messages" do
      send(Process.whereis(:rate_limiter_instance_0), :unknown_message)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(:rate_limiter_instance_0))
    end
  end

  describe "cleanup" do
    test "cleans expired entries via sharded cleanup" do
      with_rate_limiter_env(
        %{
          instance_count: :auto,
          global_limits: [%{key: :user_id, max_requests: 10, window_ms: 1000}],
          api_limits: [%{service: "s", request_type: "a", key: :user_id, max_requests: 5, window_ms: 1000}]
        },
        fn ->
          now = System.monotonic_time(:millisecond)
          old = now - 5_000
          recent = now - 100

          for i <- 1..40 do
            kind = rem(i, 3)
            timestamps =
              case kind do
                0 -> [recent, old]
                1 -> [old, old - 1]
                2 -> [recent, recent - 1]
              end

            :ets.insert(:rate_limiter_global, {"cleanup_#{i}", timestamps})
            :ets.insert(:rate_limiter_api, {"s:a:cleanup_#{i}", timestamps})
          end

          instance_count = RateLimiter.instance_count()

          for i <- 0..(instance_count - 1) do
            send(Process.whereis(:"rate_limiter_instance_#{i}"), :cleanup)
          end

          Process.sleep(100)

          remaining =
            :ets.foldl(fn {key, _ts}, acc ->
              if is_binary(key) and String.starts_with?(key, "cleanup_"), do: acc + 1, else: acc
            end, 0, :rate_limiter_global)

          assert remaining > 0
        end
      )
    end
  end

  describe "instance restart loads limits from env" do
    test "loads global and api limits as lists" do
      with_rate_limiter_env(
        %{
          instance_count: 2,
          global_limits: [%{key: :user_id, max_requests: 5, window_ms: 10_000}],
          api_limits: [%{service: "s", request_type: "a", key: :user_id, max_requests: 1, window_ms: 10_000}]
        },
        fn ->
          sup = :rate_limiter_supervisor
          :ok = Supervisor.terminate_child(sup, :rate_limiter_instance_0)
          {:ok, _pid} = Supervisor.restart_child(sup, :rate_limiter_instance_0)

          config = RateLimiter.get_configured_limits()
          assert length(config.global) == 1
          assert length(config.api) == 1
        end
      )
    end
  end

  describe "terminate/2" do
    test "stops an instance cleanly" do
      instance = Process.whereis(:rate_limiter_instance_0)
      ref = Process.monitor(instance)
      GenServer.stop(instance)
      assert_receive {:DOWN, ^ref, :process, ^instance, _reason}, 1000

      wait_for(fn -> Process.whereis(:rate_limiter_instance_0) != nil end)
    end
  end

  defp wait_for(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts == 0 do
        flunk("instance did not restart")
      else
        Process.sleep(20)
        wait_for(fun, attempts - 1)
      end
    end
  end
end