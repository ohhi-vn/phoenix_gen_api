defmodule PhoenixGenApi.Permission do
  @moduledoc """
  Provides permission checking functionality for API requests.

  This module implements a flexible permission system that can verify whether a user
  has the right to execute a specific request. Permissions can be disabled, or configured
  to check that certain request arguments match the requesting user's identity.

  ## Permission Modes

  ### Disabled Permissions (`false`)
  When `check_permission: false` is set in the FunConfig, all permission checks pass.
  This is useful for public endpoints that don't require authentication or authorization.

  ### Argument-Based Permissions (`{:arg, arg_name}`)
  When `check_permission: {:arg, arg_name}` is configured, the system verifies that
  the value of the specified argument matches the request's `user_id`. This ensures
  users can only access their own data.

  For example, with `{:arg, "user_id"}`, a request from user "123" will only be
  allowed if `request.args["user_id"] == "123"`.

  ## Examples

      # Public endpoint - no permission check
      config = %FunConfig{
        request_type: "get_public_data",
        check_permission: false
      }

      request = %Request{user_id: "any_user"}
      Permission.check_permission(request, config)
      # => true

      # User-specific endpoint - must match user_id
      config = %FunConfig{
        request_type: "get_user_profile",
        check_permission: {:arg, "user_id"}
      }

      # This passes - user accessing their own data
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_123"}
      }
      Permission.check_permission(request, config)
      # => true

      # This fails - user trying to access another user's data
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }
      Permission.check_permission(request, config)
      # => false

  ## Security Considerations

  - Always use `check_permission!/2` in the execution path to raise on failures
  - The `check_permission/2` function is non-raising and returns a boolean
  - Missing arguments result in permission denial (returns `false`)
  - Permission checks happen before argument validation and function execution
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  require Logger

  @doc """
  Checks if a request has permission to be executed based on the configuration.

  This is a non-raising version that returns a boolean result. Use this when you
  need to check permissions without raising an exception.

  ## Parameters

    - `request` - The `Request` struct containing user information and arguments
    - `fun_config` - The `FunConfig` struct with permission settings

  ## Returns

    - `true` - Permission check passed
    - `false` - Permission check failed

  ## Examples

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_123"}
      }

      config = %FunConfig{check_permission: {:arg, "user_id"}}

      if Permission.check_permission(request, config) do
        # Execute the request
      else
        # Deny access
      end
  """
  def check_permission(%Request{}, %FunConfig{check_permission: false}) do
    true
  end

  def check_permission(request = %Request{}, %FunConfig{check_permission: {:arg, arg_name}}) do
    case Map.get(request.args, arg_name) do
      nil ->
        Logger.warning(
          "gen_api, check permission, missing argument #{inspect(arg_name)} in request: #{inspect(request)}"
        )

        false

      user_id ->
        user_id == request.user_id
    end
  end

  @doc """
  Checks permission and raises an exception if the check fails.

  This is the raising version of `check_permission/2`. It should be used in the
  request execution pipeline where permission failures should halt processing.

  ## Parameters

    - `request` - The `Request` struct containing user information and arguments
    - `fun_config` - The `FunConfig` struct with permission settings

  ## Returns

    - `nil` - Permission check passed (function returns nothing on success)

  ## Raises

    - `RuntimeError` - If the permission check fails

  ## Examples

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{check_permission: {:arg, "user_id"}}

      # This will raise because user_ids don't match
      Permission.check_permission!(request, config)
      # ** (RuntimeError) Permission denied for request from user: "user_123"

  ## Notes

  - Logs a warning with request details when permission is denied
  - Always called before request execution in the Executor module
  - Returns nothing on success (only side effect is potential exception)
  """
  def check_permission!(request = %Request{}, fun_config = %FunConfig{}) do
    if not check_permission(request, fun_config) do
      Logger.warning(
        " gen_api, check permission, failed, request: #{inspect(request)}, fun config: #{inspect(fun_config)}"
      )

      raise "Permission denied for request from user: #{inspect(request.user_id)}, request: #{inspect(request.request_id)}"
    end
  end
end
