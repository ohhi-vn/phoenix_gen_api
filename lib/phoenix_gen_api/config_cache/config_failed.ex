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

  Entries expire after 24 hours. This process owns the table and sweeps expired
  entries periodically (`:config_failed_cleanup_interval`, default one hour).
  Query functions (`list/1`, `count/0`) also filter out expired entries.

  Recording is safe when the process is not running: the failure is logged and
  the caller does not crash.
  """

  use GenServer

  alias PhoenixGenApi.LogContext

  require Logger

  @table :phoenix_gen_api_config_failed
  @ttl_ms 24 * 60 * 60 * 1000
  @default_cleanup_interval 60 * 60 * 1000

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Initializes the ETS table if it does not exist. Called by the supervisor.
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          PhoenixGenApi.Security.internal_table_access(),
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        Logger.info(
          LogContext.event("ConfigFailed", :ets_initialized, ttl_ms: @ttl_ms, node: node())
        )

      _ ->
        :ok
    end

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

    cond do
      :ets.whereis(@table) == :undefined ->
        Logger.debug(fn ->
          LogContext.line(
            "ConfigFailed",
            :failure_not_stored,
            "failed config store not running, failure only logged",
            service: LogContext.value(entry.service),
            request_type: LogContext.value(entry.request_type),
            source: source
          )
        end)

      PhoenixGenApi.Security.internal_table_access() == :protected and
          Process.whereis(__MODULE__) != nil ->
        GenServer.call(__MODULE__, {:record, entry})

      true ->
        :ets.insert(@table, {id, entry})
    end

    Logger.debug(fn ->
      LogContext.line(
        "ConfigFailed",
        :failure_recorded,
        "recorded",
        id: id,
        service: LogContext.value(entry.service),
        request_type: LogContext.value(entry.request_type),
        source: source,
        node: LogContext.value(entry.node),
        reason: entry.reason
      )
    end)

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
    if :ets.whereis(@table) == :undefined do
      []
    else
      now = System.system_time(:millisecond)
      source_filter = Keyword.get(opts, :source)
      service_filter = Keyword.get(opts, :service)
      limit = Keyword.get(opts, :limit, 100)
      order = Keyword.get(opts, :order, :newest_first)

      ms = [{{:"$1", :"$2"}, [{:>, {:map_get, :expires_at_ms, :"$2"}, now}], [:"$2"]}]

      :ets.select(@table, ms)
      |> filter_entries(source_filter, service_filter)
      |> sort_entries(order)
      |> Enum.take(limit)
    end
  end

  @doc """
  Returns the count of non-expired failed entries.
  """
  @spec count() :: non_neg_integer()
  def count do
    if :ets.whereis(@table) == :undefined do
      0
    else
      now = System.system_time(:millisecond)
      ms = [{{:"$1", :"$2"}, [{:>, {:map_get, :expires_at_ms, :"$2"}, now}], [true]}]
      :ets.select_count(@table, ms)
    end
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
    if :ets.whereis(@table) == :undefined do
      0
    else
      now = System.system_time(:millisecond)

      ms = [{{:"$1", :"$2"}, [{:"=<", {:map_get, :expires_at_ms, :"$2"}, now}], [true]}]
      count = :ets.select_delete(@table, ms)

      if count > 0 do
        Logger.info(LogContext.event("ConfigFailed", :expired_entries_cleaned, count: count))
      end

      count
    end
  end

  @doc """
  Clears all entries regardless of expiry.
  """
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      :ets.delete_all_objects(@table)
      Logger.info(LogContext.event("ConfigFailed", :entries_cleared, node: node()))
      :ok
    end
  end

  @doc """
  Starts the ConfigFailed owner process under the supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    init()
    interval = cleanup_interval()
    schedule_cleanup(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call({:record, entry}, _from, state) do
    :ets.insert(@table, {entry.id, entry})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup()
    schedule_cleanup(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_interval do
    Application.get_env(:phoenix_gen_api, :config_failed_cleanup_interval) ||
      @default_cleanup_interval
  end

  # ── Private ────────────────────────────────────────────────────────

  defp normalize_reason(reason) when is_binary(reason), do: [reason]
  defp normalize_reason(reason) when is_list(reason), do: reason

  defp config_to_map(config = %PhoenixGenApi.Structs.FunConfig{}) do
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
