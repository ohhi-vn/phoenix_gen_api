defmodule PhoenixGenApi.ConfigFailed do
  @moduledoc """
  Tracks FunConfig entries that failed validation during pull or push.

  Stores the original config (as a map), the reason(s) for failure, the source
  (pull or push), the node that provided the config, and a timestamp. Entries
  auto-expire after 24 hours (TTL).

  ## ETS table

  - Named `:phoenix_gen_api_config_failed`
  - `{:set, :public, read_concurrency: true, write_concurrency: true}`
  - Key: `{id}` where `id` is a monotonically increasing integer
  - Each entry is a map with `:id`, `:service`, `:request_type`, `:version`,
    `:source`, `:node`, `:reason`, `:config`, `:inserted_at_ms`, `:expires_at_ms`

  ## TTL

  Entries expire after 24 hours. Call `cleanup/0` periodically to purge expired
  entries. Query functions (`list/1`, `count/0`) automatically filter out expired
  entries.
  """

  require Logger

  @table :phoenix_gen_api_config_failed
  @ttl_ms 24 * 60 * 60 * 1000

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Initializes the ETS table. Called by the application supervisor.
  """
  @spec init() :: :ok
  def init() do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("[ConfigFailed] initialized ETS table with #{@ttl_ms}ms TTL")
    :ok
  end

  @doc """
  Records a failed FunConfig validation.

  ## Parameters

    * `config` — the `%FunConfig{}` struct (or map) that failed
    * `reason` — a string or list of strings describing why it failed
    * `source` — `:pull` or `:push`
    * `node` — the node that provided the config (or `:local` / `nil`)

  ## Returns

  The inserted entry map.
  """
  @spec record(
          map() | PhoenixGenApi.Structs.FunConfig.t(),
          String.t() | [String.t()],
          atom(),
          atom() | nil
        ) :: map()
  def record(config, reason, source, node \\ nil) when source in [:pull, :push] do
    now = System.system_time(:millisecond)
    id = :erlang.unique_integer([:positive, :monotonic])

    entry = %{
      id: id,
      service: Map.get(config, :service) || Map.get(config, "service"),
      request_type: Map.get(config, :request_type) || Map.get(config, "request_type"),
      version: Map.get(config, :version) || Map.get(config, "version"),
      source: source,
      node: node,
      reason: normalize_reason(reason),
      config: config_to_map(config),
      inserted_at_ms: now,
      expires_at_ms: now + @ttl_ms
    }

    :ets.insert(@table, {id, entry})

    Logger.debug(
      "[ConfigFailed] recorded: id=#{id} service=#{inspect(entry.service)} request_type=#{inspect(entry.request_type)} source=#{source} reason=#{inspect(entry.reason)}"
    )

    entry
  end

  @doc """
  Returns all non-expired failed entries, optionally filtered by source.

  ## Options

    * `:source` — filter by `:pull` or `:push`
    * `:service` — filter by service name
    * `:limit` — max number of entries to return (default: 100)
    * `:order` — `:newest_first` (default) or `:oldest_first`
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    now = System.system_time(:millisecond)
    source_filter = Keyword.get(opts, :source)
    service_filter = Keyword.get(opts, :service)
    limit = Keyword.get(opts, :limit, 100)
    order = Keyword.get(opts, :order, :newest_first)

    # Select all entries where expires_at_ms > now
    ms = [{{:"$1", :"$2"}, [{:>, {:map_get, :expires_at_ms, :"$2"}, now}], [:"$2"]}]

    entries =
      :ets.select(@table, ms)
      |> filter_entries(source_filter, service_filter)
      |> sort_entries(order)
      |> Enum.take(limit)

    entries
  end

  @doc """
  Returns the count of non-expired failed entries.
  """
  @spec count() :: non_neg_integer()
  def count do
    now = System.system_time(:millisecond)
    ms = [{{:"$1", :"$2"}, [{:>, {:map_get, :expires_at_ms, :"$2"}, now}], [true]}]
    :ets.select_count(@table, ms)
  end

  @doc """
  Returns a summary of failed entries grouped by source.
  """
  @spec summary() :: map()
  def summary do
    entries = list(limit: 10_000)

    %{
      total: length(entries),
      pull: Enum.count(entries, &(&1.source == :pull)),
      push: Enum.count(entries, &(&1.source == :push)),
      by_service: Enum.group_by(entries, & &1.service),
      oldest: List.last(entries),
      newest: List.first(entries)
    }
  end

  @doc """
  Removes all expired entries from the table.
  Returns the number of entries removed.
  """
  @spec cleanup() :: non_neg_integer()
  def cleanup do
    now = System.system_time(:millisecond)

    expired_ids =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, entry} -> entry.expires_at_ms <= now end)
      |> Enum.map(fn {id, _entry} -> id end)

    count = length(expired_ids)

    if count > 0 do
      Enum.each(expired_ids, &:ets.delete(@table, &1))
      Logger.info("[ConfigFailed] cleaned up #{count} expired entries")
    end

    count
  end

  @doc """
  Clears all entries regardless of expiry.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    Logger.info("[ConfigFailed] cleared all entries")
    :ok
  end

  @doc """
  Starts the ConfigFailed table under the supervisor.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts) do
    init()
    # Return a dummy pid — the ETS table is the actual state
    {:ok, self()}
  end

  # ── Private ────────────────────────────────────────────────────────

  defp normalize_reason(reason) when is_binary(reason), do: [reason]
  defp normalize_reason(reason) when is_list(reason), do: reason

  defp config_to_map(%PhoenixGenApi.Structs.FunConfig{} = config) do
    Map.from_struct(config)
  end

  defp config_to_map(config) when is_map(config), do: config

  defp filter_entries(entries, nil, nil), do: entries

  defp filter_entries(entries, source, nil) do
    Enum.filter(entries, &(&1.source == source))
  end

  defp filter_entries(entries, nil, service) do
    Enum.filter(entries, &(&1.service == service))
  end

  defp filter_entries(entries, source, service) do
    Enum.filter(entries, &(&1.source == source and &1.service == service))
  end

  defp sort_entries(entries, :newest_first) do
    Enum.sort_by(entries, & &1.inserted_at_ms, :desc)
  end

  defp sort_entries(entries, :oldest_first) do
    Enum.sort_by(entries, & &1.inserted_at_ms, :asc)
  end
end
