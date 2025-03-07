# help phoenix can decode struct to json.
# if can, decode to map before pass result to location_service.

alias PhoenixGenApi.Structs.{Response}

require Logger

use PhoenixGenApi.JasonImplHelper,
  impl: [
    Response
  ]
