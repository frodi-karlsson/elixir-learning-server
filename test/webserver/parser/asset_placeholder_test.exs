defmodule Webserver.Parser.AssetPlaceholderTest do
  use ExUnit.Case, async: true

  alias Webserver.Parser
  alias Webserver.Parser.ParseInput

  @parse_input %ParseInput{
    partials: %{},
    template_dir: "/priv/templates",
    asset_resolver: Webserver.AssetResolver.Sandbox
  }

  test "should resolve {{+ /static/...}} placeholder to hashed path" do
    input = ~S(<link href="{{+ /static/css/app.css}}">)

    result = Parser.parse(%{@parse_input | file: input})

    assert result == {:ok, ~S(<link href="/static/css/app.testhash.css">)}
  end

  test "should handle quoted asset placeholder" do
    input = ~S(<link href="{{+ '/static/css/app.css'}}">)

    result = Parser.parse(%{@parse_input | file: input})

    assert result == {:ok, ~S(<link href="/static/css/app.testhash.css">)}
  end

  test "should return error for unknown asset placeholder" do
    input = ~S(<link href="{{+ /static/css/missing.css}}">)

    result = Parser.parse(%{@parse_input | file: input})

    assert result == {:error, {:unresolved_asset, "/static/css/missing.css"}}
  end
end
