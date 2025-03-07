[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/easy_rpc)
[![Hex.pm](https://img.shields.io/hexpm/v/easy_rpc.svg?style=flat&color=blue)](https://hex.pm/packages/easy_rpc)

# PhoenixGenApi

The library help fast develop and api based on Phoenix Channel.

## Concept

After received an event from client(handle_in) Phoenix Channel process will pass data to PhoenixGenApi to find final event & target node to execute than get result to response to client.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phoenix_gen_api` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_gen_api, "~> 0.0.1"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/phoenix_gen_api>.

The library is still in development phase but can use.
We will update more in the future.
