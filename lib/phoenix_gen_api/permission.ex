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

  ### Any Authenticated (`:any_authenticated`)
  When `check_permission: :any_authenticated` is configured, the system verifies that
  the request has a valid `user_id`. Any authenticated user is allowed access.

  ### Argument-Based Permissions (`{:arg, arg_name}`)
  When `check_permission: {:arg, arg_name}` is configured, the system verifies that
  the value of the specified argument matches the request's `user_id`. This ensures
  users can only access their own data.

  For example, with `{:arg, "user_id"}`, a request from user "123" will only be
  allowed if `request.args["user_id"] == "123"`.

  ### Role-Based Permissions (`{:role, allowed_roles}`)
  When `check_permission: {:role, allowed_roles}` is configured, the system verifies
  that the user has one of the allowed roles. Roles are checked against the
  `request.user_roles` field (must be a list of strings or atoms).

  For example, with `{:role, ["admin", "moderator"]}`, only users with those roles
  are allowed access.

  ## Examples

      # Public endpoint - no permission check
      config = %FunConfig{
        request_type: "get_public_data",
        check_permission: false
      }

      request = %Request{user_id: "any_user"}
      Permission.check_permission(request, config)
      # => true

      # Any authenticated user
      config = %FunConfig{
        request_type: "get_profile",
        check_permission: :any_authenticated
      }

      request = %Request{user_id: "user_123"}
      Permission.check_permission(request, config)
      # => true

      request = %Request{user_id: nil}
      Permission.check_permission(request, config)
      # => false

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

      # Role-based access
      config = %FunConfig{
        request_type: "delete_user",
        check_permission: {:role, ["admin"]}
      }

      request = %Request{
        user_id: "user_123",
        user_roles: ["admin"]
      }
      Permission.check_permission(request, config)
      # => true

  ## Security Considerations

  - Always use `check_permission!/2` in the execution path to raise on failures
  - The `check_permission/2` function is non-raising and returns a boolean
  - Missing arguments result in permission denial (returns `false`)
  - Permission checks happen before argument validation and function execution
  - All permission failures are logged for audit purposes
  - Use specific permission modes rather than `false` when possible
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  require Logger

  @doc """
  Exception raised when a permission check fails.

  Contains details about the request and the permission mode that was denied.
  """
  defmodule PermissionDenied do
    @moduledoc false

    defexception [:message, :user_id, :request_id, :request_type, :permission_mode]

    @impl true
    def exception(opts) do
      user_id = Keyword.get(opts, :user_id)
      request_id = Keyword.get(opts, :request_id)
      request_type = Keyword.get(opts, :request_type)
      permission_mode = Keyword.get(opts, :permission_mode)

      message =
        "Permission denied for user: #{inspect(user_id)}, " <>
          "request: #{inspect(request_id)}, " <>
          "type: #{inspect(request_type)}, " <>
          "mode: #{inspect(permission_mode)}"

      %__MODULE__{
        message: message,
        user_id: user_id,
        request_id: request_id,
        request_type: request_type,
        permission_mode: permission_mode
      }
    end
  end

  def check_permission(%Request{}, %FunConfig{check_permission: false}) do
    true
  end

  def check_permission(%Request{user_id: user_id}, %FunConfig{check_permission: :any_authenticated})
      when is_binary(user_id) or is_nil(user_id) do
    true
  end

  def check_permission(%Request{user_id: nil}, %FunConfig{check_permission: :any_authenticated}) do
    false
  end

  def check_permission(%Request{user_id: user_id}, %FunConfig{check_permission: :any_authenticated})
      when is_binary(user_id) and byte_size(user_id) > 0 do
    true
  end

  def check_permission(%Request{}, %FunConfig{check_permission: :any_authenticated}) do
    false
  end

  def check_permission(
        request = %Request{user_id: user_id},
        %FunConfig{check_permission: {:arg, arg_name}}
      )
      when is_binary(user_id) and byte_size(user_id) > 0 do
    case Map.get(request.args, arg_name) do
      nil ->
        Logger.warning(
          "PhoenixGenApi.Permission, check_permission, missing argument #{inspect(arg_name)} in request: #{inspect(request.request_id)}"
        )

        false

      ^user_id ->
        true

      _other ->
        false
    end
  end

  def check_permission(%Request{}, %FunConfig{check_permission: {:arg, _arg_name}}) do
    false
  end

  def check_permission(
        %Request{user_roles: user_roles} = request,
        %FunConfig{check_permission: {:role, allowed_roles}}
      )
      when is_list(user_roles) and is_list(allowed_roles) do
    allowed_roles_set = MapSet.new(allowed_roles)
    user_roles_set = MapSet.new(user_roles)

    case MapSet.intersection(user_roles_set, allowed_roles_set) |> MapSet.size() do
      0 ->
        Logger.warning(
          "PhoenixGenApi.Permission, check_permission, user #{inspect(request.user_id)} lacks required roles, request: #{inspect(request.request_id)}"
        )

        false

      _ ->
        true
    end
  end

  def check_permission(%Request{}, %FunConfig{check_permission: {:role, _allowed_roles}}) do
    false
  end

  def check_permission(%Request{}, fun_config = %FunConfig{}) do
    Logger.error(
      "PhoenixGenApi.Permission, check_permission, invalid permission mode: #{inspect(fun_config.check_permission)}"
    )

    false
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

    - `PermissionDenied` - If the permission check fails

  ## Examples

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{check_permission: {:arg, "user_id"}}

      # This will raise because user_ids don't match
      Permission.check_permission!(request, config)
      # ** (PhoenixGenApi.Permission.PermissionDenied) Permission denied...

  ## Notes

  - Logs a warning with request details when permission is denied
  - Always called before request execution in the Executor module
  - Returns nothing on success (only side effect is potential exception)
  """
  def check_permission!(request = %Request{}, fun_config = %FunConfig{}) do
    if not check_permission(request, fun_config) do
      Logger.warning(
        "PhoenixGenApi.Permission, check_permission!, denied, user: #{inspect(request.user_id)}, " <>
          "request_id: #{inspect(request.request_id)}, " <>
          "request_type: #{inspect(request.request_type)}, " <>
          "permission_mode: #{inspect(fun_config.check_permission)}"
      )

      raise PermissionDenied,
        user_id: request.user_id,
        request_id: request.request_id,
        request_type: request.request_type,
        permission_mode: fun_config.check_permission
    end

    nil
  end
end
