defmodule PhoenixGenApi.SecurityTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Security

  describe "admin_action_allowed?/1" do
    test "returns false for all actions when no config set" do
      # Ensure no admin_actions configured
      original = Application.get_env(:phoenix_gen_api, :admin_actions)
      Application.delete_env(:phoenix_gen_api, :admin_actions)

      try do
        refute Security.admin_action_allowed?(:change_detail_error)
        refute Security.admin_action_allowed?(:update_rate_limit_config)
        refute Security.admin_action_allowed?(:push_config)
        refute Security.admin_action_allowed?(:enable_tracing)
        refute Security.admin_action_allowed?(:disable_tracing)
      after
        Application.put_env(:phoenix_gen_api, :admin_actions, original)
      end
    end

    test "returns true only for configured actions" do
      original = Application.get_env(:phoenix_gen_api, :admin_actions)
      Application.put_env(:phoenix_gen_api, :admin_actions, [:push_config, :enable_tracing])

      try do
        assert Security.admin_action_allowed?(:push_config)
        assert Security.admin_action_allowed?(:enable_tracing)
        refute Security.admin_action_allowed?(:change_detail_error)
        refute Security.admin_action_allowed?(:update_rate_limit_config)
        refute Security.admin_action_allowed?(:disable_tracing)
      after
        Application.put_env(:phoenix_gen_api, :admin_actions, original)
      end
    end

    test "returns true when all actions are configured" do
      all_actions = [
        :change_detail_error,
        :update_rate_limit_config,
        :push_config,
        :enable_tracing,
        :disable_tracing
      ]

      original = Application.get_env(:phoenix_gen_api, :admin_actions)
      Application.put_env(:phoenix_gen_api, :admin_actions, all_actions)

      try do
        Enum.each(all_actions, fn action ->
          assert Security.admin_action_allowed?(action)
        end)
      after
        Application.put_env(:phoenix_gen_api, :admin_actions, original)
      end
    end

    test "returns true for single action in allowlist" do
      original = Application.get_env(:phoenix_gen_api, :admin_actions)
      Application.put_env(:phoenix_gen_api, :admin_actions, [:update_rate_limit_config])

      try do
        assert Security.admin_action_allowed?(:update_rate_limit_config)
        refute Security.admin_action_allowed?(:push_config)
      after
        Application.put_env(:phoenix_gen_api, :admin_actions, original)
      end
    end
  end

  describe "valid_push_token?/1" do
    test "returns true when no push token is configured (nil token)" do
      Application.delete_env(:phoenix_gen_api, :push_token)
      assert Security.valid_push_token?(nil) == true
    end

    test "returns true for any token when no push token configured" do
      Application.delete_env(:phoenix_gen_api, :push_token)
      assert Security.valid_push_token?("anything") == true
    end

    test "returns false for nil token when token is configured" do
      Application.put_env(:phoenix_gen_api, :push_token, "secret123")
      assert Security.valid_push_token?(nil) == false
      Application.delete_env(:phoenix_gen_api, :push_token)
    end

    test "returns true for matching token" do
      Application.put_env(:phoenix_gen_api, :push_token, "secret123")
      assert Security.valid_push_token?("secret123") == true
      Application.delete_env(:phoenix_gen_api, :push_token)
    end

    test "returns false for non-matching token" do
      Application.put_env(:phoenix_gen_api, :push_token, "secret123")
      refute Security.valid_push_token?("wrong_token")
      Application.delete_env(:phoenix_gen_api, :push_token)
    end

    test "returns false for empty string token when token is configured" do
      Application.put_env(:phoenix_gen_api, :push_token, "secret123")
      refute Security.valid_push_token?("")
      Application.delete_env(:phoenix_gen_api, :push_token)
    end

    test "returns false for non-binary token" do
      Application.put_env(:phoenix_gen_api, :push_token, "secret123")
      refute Security.valid_push_token?(:atom_token)
      refute Security.valid_push_token?(123)
      Application.delete_env(:phoenix_gen_api, :push_token)
    end

    test "uses constant-time comparison (works for different length tokens)" do
      Application.put_env(:phoenix_gen_api, :push_token, "a_long_secret_token")
      # Different length should return false without crashing
      refute Security.valid_push_token?("short")
      refute Security.valid_push_token?("a_long_secret_token_extra")
      Application.delete_env(:phoenix_gen_api, :push_token)
    end
  end

  describe "validate_mfa/1" do
    test "returns :ok for non-denylisted module when no allowlist configured" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
      assert Security.validate_mfa({MyModule, :my_function, []}) == :ok
    end

    test "returns :ok for non-denylisted module with args when no allowlist configured" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
      assert Security.validate_mfa({MyModule, :my_function, [:arg1, :arg2]}) == :ok
    end

    test "returns error for hardcoded denylist module :os" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:os, :cmd, _}}} =
               Security.validate_mfa({:os, :cmd, ["echo hello"]})
    end

    test "returns error for hardcoded denylist module :file" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:file, :write, _}}} =
               Security.validate_mfa({:file, :write, ["path", "data"]})
    end

    test "returns error for hardcoded denylist module :code" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:code, :load_file, _}}} =
               Security.validate_mfa({:code, :load_file, [:mod]})
    end

    test "returns error for hardcoded denylist module :erlang" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:erlang, :spawn, _}}} =
               Security.validate_mfa({:erlang, :spawn, [:fun]})
    end

    test "returns error for hardcoded denylist module :net" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, :net}} =
               Security.validate_mfa(:net)
    end

    test "returns error for hardcoded denylist module :rpc" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:rpc, :call, _}}} =
               Security.validate_mfa({:rpc, :call, [:node, :mod, :fun, []]})
    end

    test "returns error for hardcoded denylist module :global" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:global, :register_name, _}}} =
               Security.validate_mfa({:global, :register_name, [:name, :pid]})
    end

    test "returns error for hardcoded denylist module :inet" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, {:inet, :getaddr, _}}} =
               Security.validate_mfa({:inet, :getaddr, [:host, :inet]})
    end

    test "returns :ok when MFA is in allowlist (module-level)" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [MyApp.UserService])

      assert Security.validate_mfa({MyApp.UserService, :any_function, []}) == :ok

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "returns :ok when MFA matches specific {module, function} tuple" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [{MyApp.Order, :create}])

      assert Security.validate_mfa({MyApp.Order, :create, []}) == :ok

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "returns error when MFA module is in allowlist but function is not (specific tuple)" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [{MyApp.Order, :create}])

      assert {:error, {:mfa_not_allowed, _}} =
               Security.validate_mfa({MyApp.Order, :delete, []})

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "returns error when MFA is not in allowlist" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [MyApp.UserService])

      assert {:error, {:mfa_not_allowed, _}} =
               Security.validate_mfa({MyApp.OtherService, :function, []})

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "module-level allowlist entry allows all functions in that module" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [MyApp.UserService])

      assert Security.validate_mfa({MyApp.UserService, :create, []}) == :ok
      assert Security.validate_mfa({MyApp.UserService, :update, []}) == :ok
      assert Security.validate_mfa({MyApp.UserService, :delete, []}) == :ok
      assert Security.validate_mfa({MyApp.UserService, :very_long_function_name, []}) == :ok

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "mixed allowlist with module atoms and tuples" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [
        MyApp.UserService,
        {MyApp.Order, :create},
        {MyApp.Order, :cancel}
      ])

      # Module-level entry
      assert Security.validate_mfa({MyApp.UserService, :anything, []}) == :ok
      # Specific tuples
      assert Security.validate_mfa({MyApp.Order, :create, []}) == :ok
      assert Security.validate_mfa({MyApp.Order, :cancel, []}) == :ok
      # Not in allowlist
      assert {:error, _} = Security.validate_mfa({MyApp.Order, :delete, []})
      assert {:error, _} = Security.validate_mfa({MyApp.Product, :create, []})

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "returns error for invalid MFA format (not a tuple)" do
      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)

      assert {:error, {:mfa_not_allowed, :invalid}} = Security.validate_mfa(:invalid)
      assert {:error, {:mfa_not_allowed, "string"}} = Security.validate_mfa("string")
      assert {:error, {:mfa_not_allowed, nil}} = Security.validate_mfa(nil)
      assert {:error, {:mfa_not_allowed, 123}} = Security.validate_mfa(123)
    end

    test "returns error for denylisted module even if in allowlist" do
      # Denylist always takes precedence
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [:os])

      assert {:error, {:mfa_not_allowed, _}} =
               Security.validate_mfa({:os, :cmd, ["echo"]})

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end

    test "empty allowlist denies everything except denylist" do
      Application.put_env(:phoenix_gen_api, :mfa_allowlist, [])

      assert {:error, _} = Security.validate_mfa({MyModule, :my_fn, []})

      Application.delete_env(:phoenix_gen_api, :mfa_allowlist)
    end
  end
end
