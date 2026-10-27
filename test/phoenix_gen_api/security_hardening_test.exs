defmodule PhoenixGenApi.SecurityHardeningTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.{ConfigDb, NodeSelector, Security, Tracer}
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}

  def ok_fun, do: {:ok, :ok}

  defp unique, do: System.unique_integer([:positive])

  defp register(request_type, overrides) do
    config =
      struct(
        %FunConfig{
          request_type: request_type,
          service: "sec_service",
          nodes: :local,
          choose_node_mode: :random,
          timeout: 5_000,
          mfa: {__MODULE__, :ok_fun, []},
          arg_types: %{},
          arg_orders: [],
          response_type: :sync,
          check_permission: false,
          request_info: false
        },
        overrides
      )

    :ok = ConfigDb.add(config)
    on_exit(fn -> ConfigDb.delete(config.service, config.request_type) end)
    config
  end

  defp compile_channel!(opts_code) do
    module_name = Module.concat(__MODULE__, "Channel#{unique()}")

    code = """
    defmodule #{inspect(module_name)} do
      use PhoenixGenApi#{opts_code}

      def push(socket, event, payload) do
        send(socket.ref, {:pushed, event, payload})
        socket
      end
    end
    """

    Code.compile_string(code)
    module_name
  end

  defp payload(request_type, overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "sec_req_#{unique()}",
        "request_type" => request_type,
        "service" => "sec_service",
        "user_id" => "sec_user",
        "args" => %{}
      },
      overrides
    )
  end

  describe "MFA safety rules" do
    test "dangerous Elixir and runtime modules are denied by default" do
      for mfa <- [
            {File, :write, ["/tmp/x", "y"]},
            {Code, :eval_string, ["1 + 1"]},
            {System, :cmd, ["echo hi"]},
            {Node, :connect, [:other@host]},
            {:ets, :delete_all_objects, [:some_table]},
            {:application, :put_env, [:phoenix_gen_api, :push_token, "x"]}
          ] do
        assert {:error, {:mfa_not_allowed, ^mfa}} = Security.validate_mfa(mfa)
      end
    end

    test "an explicit allowlist entry is the escape hatch" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [File])

      on_exit(fn -> Application.delete_env(:phoenix_gen_api, :mfa_allowlist) end)

      assert :ok = Security.validate_mfa({File, :write, ["/tmp/x", "y"]})
      assert {:error, {:mfa_not_allowed, _}} = Security.validate_mfa({Code, :eval_string, ["1"]})
    end
  end

  describe "push token comparison" do
    test "tokens of many lengths are rejected without matching" do
      Application.put_env(:phoenix_gen_api, :push_token, "the-configured-secret")

      on_exit(fn -> Application.delete_env(:phoenix_gen_api, :push_token) end)

      for length <- [0, 1, 5, 10, 20, 21, 22, 40, 200] do
        candidate = String.duplicate("x", length)
        refute Security.valid_push_token?(candidate)
      end

      assert Security.valid_push_token?("the-configured-secret")
    end
  end

  describe "atom safety" do
    test "unknown sticky key names do not create atoms" do
      for i <- 1..50 do
        config = %FunConfig{
          request_type: "sec_sticky",
          service: "sec_service",
          nodes: [:nonode@nohost],
          choose_node_mode: {:sticky, "unknown_field_#{i}"}
        }

        request = %Request{
          request_id: "sticky_#{i}",
          request_type: "sec_sticky",
          service: "sec_service",
          args: %{}
        }

        NodeSelector.get_node(config, request)
      end

      # The key strings were never interned: resolving them as existing atoms
      # still fails after the lookups.
      for i <- 1..50 do
        assert_raise ArgumentError, fn ->
          String.to_existing_atom("unknown_field_#{i}")
        end
      end
    end
  end

  describe "tracing administration" do
    test "tracing control is denied when the admin action is not allowed" do
      original = Application.get_env(:phoenix_gen_api, :admin_actions)

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_gen_api, :admin_actions, original),
          else: Application.delete_env(:phoenix_gen_api, :admin_actions)
      end)

      Application.put_env(:phoenix_gen_api, :admin_actions, [:change_detail_error])

      assert {:error, :admin_action_denied} = Tracer.set_enabled(true)
      assert {:error, :admin_action_denied} = Tracer.enable_request_type("sec_trace")
      assert {:error, :admin_action_denied} = Tracer.enable_user_id("sec_user")
    end

    test "argument capture can be disabled" do
      log_dir =
        Path.join(System.tmp_dir!(), "pga_sec_trace_#{System.unique_integer([:positive])}")

      original_capture = Application.get_env(:phoenix_gen_api, :trace_capture_args)

      on_exit(fn ->
        Tracer.clear()
        Tracer.set_enabled(false)

        if original_capture,
          do: Application.put_env(:phoenix_gen_api, :trace_capture_args, original_capture),
          else: Application.delete_env(:phoenix_gen_api, :trace_capture_args)

        File.rm_rf(log_dir)
      end)

      :ok = Tracer.configure(log_dir: log_dir)
      :ok = Tracer.set_enabled(true)
      :ok = Tracer.enable_request_type("sec_capture")

      Application.put_env(:phoenix_gen_api, :trace_capture_args, false)

      request = %Request{
        request_id: "sec_capture_req",
        request_type: "sec_capture",
        user_id: "sec_capture_user",
        service: "sec_service",
        args: %{"secret" => "super-secret-value"}
      }

      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      content = File.read!(Path.join(log_dir, "request_type-sec_capture.log"))
      refute content =~ "super-secret-value"
      assert content =~ "event=request_start"
    end
  end

  describe "channel identity flags" do
    test "payload roles are ignored when require_authenticated_roles is enabled" do
      channel = compile_channel!(", require_authenticated_roles: true")
      request_type = "sec_roles_#{unique()}"
      register(request_type, %{check_permission: {:role, ["admin"]}})

      socket = %{
        ref: self(),
        assigns: %{user_id: "sec_user", user_roles: ["admin"]}
      }

      # Payload claims admin, socket has admin — allowed.
      channel.handle_in(
        "phoenix_gen_api",
        payload(request_type, %{"user_roles" => ["admin"]}),
        socket
      )

      assert_receive {:pushed, _, %Response{success: true}}

      # Payload claims admin, socket has no roles — denied.
      channel.handle_in(
        "phoenix_gen_api",
        payload(request_type, %{"user_roles" => ["admin"]}),
        %{socket | assigns: %{user_id: "sec_user"}}
      )

      assert_receive {:pushed, _, %Response{success: false, error: "Permission denied"}}
    end

    test "an unverified payload user_id is treated as absent when enabled" do
      channel =
        compile_channel!(", reject_unverified_user_id: true, require_verified_user_id: false")

      request_type = "sec_identity_#{unique()}"
      register(request_type, %{check_permission: :any_authenticated})

      # No verified user_id on the socket: the payload identifier is discarded.
      channel.handle_in(
        "phoenix_gen_api",
        payload(request_type, %{"user_id" => "victim"}),
        %{ref: self(), assigns: %{}}
      )

      assert_receive {:pushed, _, %Response{success: false, error: "Permission denied"}}

      # Verified user on the socket: the request is authenticated.
      channel.handle_in(
        "phoenix_gen_api",
        payload(request_type, %{"user_id" => "victim"}),
        %{ref: self(), assigns: %{user_id: "real_user"}}
      )

      assert_receive {:pushed, _, %Response{success: true}}
    end
  end

  describe "internal table access" do
    test "the access mode follows the hardening flag" do
      original = Application.get_env(:phoenix_gen_api, :protect_internal_tables)

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_gen_api, :protect_internal_tables, original),
          else: Application.delete_env(:phoenix_gen_api, :protect_internal_tables)
      end)

      Application.delete_env(:phoenix_gen_api, :protect_internal_tables)
      assert Security.internal_table_access() == :public

      Application.put_env(:phoenix_gen_api, :protect_internal_tables, true)
      assert Security.internal_table_access() == :protected
    end
  end
end
