# impl-helper-encoder specification

## Purpose

ImplHelper generates JSON-encoder protocol implementations (`gen_impl`, `__using__`) for structs that expose `encode!/2`. This capability defines that generated implementations conform to the encoder protocol contract so that PhoenixGenApi response structs and any struct registered through ImplHelper serialize correctly over Phoenix channel wire transport.

## Requirements

### Requirement: Generated impls conform to the encoder protocol contract

ImplHelper SHALL generate `encode/2` implementations that first apply the struct's `encode!/2`, then recursively encode the returned value via the encoder protocol itself, returning output valid as iodata per the encoder protocol contract (`Jason.Encoder`, OTP `JSON.Encoder`, or any protocol passed as the `:encoder` option).

#### Scenarios

- **WHEN** a struct registered through `gen_impl` is encoded as a nested value (`JSON.encode!(%{"key" => struct})`)
- **THEN** encoding succeeds and the struct appears in the output as its `encode!/2`-produced JSON object

- **WHEN** a struct registered through `gen_impl` is encoded at the top level (`JSON.encode!(struct)`)
- **THEN** encoding succeeds with the same JSON object

- **WHEN** a struct registered through `gen_impl` is encoded inside a list (`JSON.encode!([join_ref, ref, topic, event, struct])`)
- **THEN** encoding succeeds and every element is JSON-encoded, including the struct

### Requirement: use PhoenixGenApi channels produce wire-serializable responses

A Phoenix channel that does `use PhoenixGenApi` SHALL generate a `JSON.Encoder` (or configured-library Encoder) implementation for `PhoenixGenApi.Structs.Response` that serializes sync, async, and error responses correctly over Phoenix channel wire transport, without crashing the channel process.

#### Scenarios

- **WHEN** a client joins a channel backed by `use PhoenixGenApi` and pushes a sync request over a real websocket transport, with `config :phoenix, :json_library, Jason` (Phoenix default) or OTP's `JSON`
- **THEN** the channel process does not crash

- **WHEN** the same request completes
- **THEN** the client receives the response on the configured event as a JSON object containing `request_id`, `success`, and the request's `result` or `error`

### Requirement: Encoder option evaluation

ImplHelper SHALL resolve its `:encoder` and `:impl` options at macro-expansion time, supporting both literal module atoms and compile-time expressions such as `Module.concat(Application.compile_env(:phoenix, :json_library, JSON), Encoder)`.

#### Scenarios

- **WHEN** a channel does `use PhoenixGenApi` and `config :phoenix, :json_library` is `Jason` (or unset, defaulting per library config)
- **THEN** the generated impl targets the configured library's Encoder protocol

- **WHEN** a module calls `PhoenixGenApi.ImplHelper.gen_impl(SomeProtocol, SomeStruct)` with literal module atoms
- **THEN** an implementation of `SomeProtocol` for `SomeStruct` is generated that delegates to `SomeStruct.encode!/2` followed by `SomeProtocol.encode/2` on the result
