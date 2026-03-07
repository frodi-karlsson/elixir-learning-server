defmodule Webserver.Parser.ImgTagTest do
  use ExUnit.Case, async: true

  alias Webserver.Parser
  alias Webserver.Parser.ParseInput

  @parse_input %ParseInput{
    partials: %{},
    template_dir: "/priv/templates",
    asset_resolver: Webserver.AssetResolver.Sandbox
  }

  test "should render <picture> with webp variant and width/height" do
    input = ~S(<% img src='/static/img/web-vitals.png' alt='Vitals' %/>)

    result = Parser.parse(%{@parse_input | file: input})

    assert result ==
             {:ok,
              ~S(<picture><source type="image/webp" srcset="/static/img/web-vitals.w728.testhash.webp 728w, /static/img/web-vitals.testhash.webp 876w"><img src="/static/img/web-vitals.testhash.png" alt="Vitals" width="876" height="378" srcset="/static/img/web-vitals.w728.testhash.png 728w, /static/img/web-vitals.testhash.png 876w" decoding="async" /></picture>)}
  end

  test "should escape alt text" do
    input = ~S(<% img src='/static/img/web-vitals.png' alt='a"b<c&d' %/>)

    result = Parser.parse(%{@parse_input | file: input})

    assert result ==
             {:ok,
              ~S(<picture><source type="image/webp" srcset="/static/img/web-vitals.w728.testhash.webp 728w, /static/img/web-vitals.testhash.webp 876w"><img src="/static/img/web-vitals.testhash.png" alt="a&quot;b&lt;c&amp;d" width="876" height="378" srcset="/static/img/web-vitals.w728.testhash.png 728w, /static/img/web-vitals.testhash.png 876w" decoding="async" /></picture>)}
  end

  test "should error for non-image src" do
    input = ~S(<% img src='/static/css/app.css' alt='nope' %/>)

    result = Parser.parse(%{@parse_input | file: input})

    assert result == {:error, {:non_image_src, "/static/css/app.css"}}
  end

  test "should error for missing image metadata" do
    input = ~S(<% img src='/static/img/no-meta.png' alt='No Meta' %/>)

    result = Parser.parse(%{@parse_input | file: input})

    assert result == {:error, {:unresolved_image_meta, "/static/img/no-meta.png"}}
  end
end
