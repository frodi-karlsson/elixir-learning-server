defmodule Webserver.Parser.Img do
  @moduledoc """
  Implements the `<% img ... %/>` tag.

  Responsibilities:

  - Validates that `src` points at a `/static/` image
  - Resolves digested asset paths (in non-live-reload mode)
  - Looks up width/height from `Webserver.AssetServer` metadata
  - Builds responsive `srcset` and an optional WebP `<picture>` wrapper
  """

  alias Webserver.Parser.ParseInput

  @image_extensions Webserver.Assets.image_extensions()
  @responsive_widths Webserver.Assets.responsive_widths()

  @spec render(map(), ParseInput.t()) :: {:ok, iodata()} | {:error, any()}
  def render(attrs, %ParseInput{} = parse_input) when is_map(attrs) do
    with {:ok, src} <- fetch_attr(attrs, "src"),
         {:ok, alt} <- fetch_attr(attrs, "alt"),
         :ok <- validate_image_src(src),
         {:ok, resolved_src} <- resolve_asset(src, parse_input),
         {:ok, {width, height}} <- resolve_image_meta(src, parse_input) do
      decoding = Map.get(attrs, "decoding", "async")
      loading = Map.get(attrs, "loading")
      class = Map.get(attrs, "class")
      sizes = Map.get(attrs, "sizes")

      fallback_srcset = maybe_build_fallback_srcset(src, resolved_src, width, parse_input)

      img_opts = %{
        src: resolved_src,
        alt: alt,
        width: width,
        height: height,
        class: class,
        loading: loading,
        decoding: decoding,
        srcset: fallback_srcset,
        sizes: sizes
      }

      case maybe_resolve_webp_variant(src, parse_input) do
        {:ok, resolved_webp} ->
          webp_srcset = maybe_build_webp_srcset(src, resolved_webp, width, parse_input)

          {:ok,
           picture_iodata(%{webp_src: resolved_webp, webp_srcset: webp_srcset, img: img_opts})}

        {:error, :no_variant} ->
          {:ok, img_iodata(img_opts)}
      end
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, {:missing_attrs, [key]}}
    end
  end

  defp validate_image_src(src) when is_binary(src) do
    if String.starts_with?(src, "/static/") and Path.extname(src) in @image_extensions do
      :ok
    else
      {:error, {:non_image_src, src}}
    end
  end

  defp resolve_image_meta(src, %ParseInput{} = parse_input) when is_binary(src) do
    case parse_input.asset_resolver.resolve_meta(src) do
      {:ok, %{width: width, height: height}} when is_integer(width) and is_integer(height) ->
        {:ok, {width, height}}

      _ ->
        {:error, {:unresolved_image_meta, src}}
    end
  end

  defp resolve_asset(path, %ParseInput{} = parse_input) do
    if Application.get_env(:webserver, :live_reload, false) do
      {:ok, path}
    else
      case parse_input.asset_resolver.resolve(path) do
        {:ok, resolved} -> {:ok, resolved}
        {:error, :not_found} -> {:error, {:unresolved_asset, path}}
      end
    end
  end

  defp maybe_resolve_webp_variant(src, parse_input) do
    if Path.extname(src) in Webserver.Assets.raster_extensions() do
      webp = Path.rootname(src) <> ".webp"

      case resolve_asset(webp, parse_input) do
        {:ok, resolved_webp} -> {:ok, resolved_webp}
        {:error, {:unresolved_asset, _path}} -> {:error, :no_variant}
      end
    else
      {:error, :no_variant}
    end
  end

  defp maybe_build_fallback_srcset(src, resolved_src, original_width, parse_input)
       when is_binary(src) and is_binary(resolved_src) and is_integer(original_width) do
    candidates =
      @responsive_widths
      |> Enum.filter(&(&1 < original_width))
      |> Enum.map(&{responsive_variant_path(src, &1), &1})
      |> Enum.flat_map(fn {path, w} ->
        case resolve_asset_for_srcset(path, parse_input) do
          {:ok, resolved} -> [{resolved, w}]
          :error -> []
        end
      end)

    if candidates == [] do
      nil
    else
      srcset_string(candidates ++ [{resolved_src, original_width}])
    end
  end

  defp maybe_build_webp_srcset(src, resolved_webp, original_width, parse_input)
       when is_binary(src) and is_binary(resolved_webp) and is_integer(original_width) do
    base = Path.rootname(src)

    candidates =
      @responsive_widths
      |> Enum.filter(&(&1 < original_width))
      |> Enum.map(&{"#{base}.w#{&1}.webp", &1})
      |> Enum.flat_map(fn {path, w} ->
        case resolve_asset_for_srcset(path, parse_input) do
          {:ok, resolved} -> [{resolved, w}]
          :error -> []
        end
      end)

    if candidates == [] do
      nil
    else
      srcset_string(candidates ++ [{resolved_webp, original_width}])
    end
  end

  defp responsive_variant_path(src, w) when is_binary(src) and is_integer(w) do
    base = Path.rootname(src)
    ext = Path.extname(src)
    "#{base}.w#{w}#{ext}"
  end

  defp srcset_string(candidates) when is_list(candidates) do
    candidates
    |> Enum.sort_by(fn {_url, w} -> w end)
    |> Enum.map_join(", ", fn {url, w} -> "#{url} #{w}w" end)
  end

  defp resolve_asset_for_srcset(path, %ParseInput{} = parse_input) when is_binary(path) do
    if Application.get_env(:webserver, :live_reload, false) do
      if static_file_exists?(path) do
        {:ok, path}
      else
        :error
      end
    else
      case parse_input.asset_resolver.resolve(path) do
        {:ok, resolved} -> {:ok, resolved}
        {:error, :not_found} -> :error
      end
    end
  end

  defp static_file_exists?(path) when is_binary(path) do
    if String.starts_with?(path, "/static/") do
      rel = String.trim_leading(path, "/static/")
      static_dir = Path.join(to_string(:code.priv_dir(:webserver)), "static")
      File.exists?(Path.join(static_dir, rel))
    else
      false
    end
  end

  defp img_iodata(%{src: src, alt: alt, width: width, height: height} = opts)
       when is_binary(src) and is_binary(alt) and is_integer(width) and is_integer(height) do
    class_attr = optional_attr("class", Map.get(opts, :class))
    loading_attr = optional_attr("loading", Map.get(opts, :loading))

    srcset = Map.get(opts, :srcset)
    sizes = Map.get(opts, :sizes)
    decoding = Map.get(opts, :decoding, "async")

    srcset_attr = optional_attr("srcset", srcset)
    sizes_attr = optional_attr("sizes", sizes_for_srcset(srcset, sizes))

    src = escape_attr(src)
    alt = escape_attr(alt)
    decoding = escape_attr(decoding)

    [
      "<img src=\"",
      src,
      "\" alt=\"",
      alt,
      "\" width=\"",
      Integer.to_string(width),
      "\" height=\"",
      Integer.to_string(height),
      "\"",
      class_attr,
      loading_attr,
      srcset_attr,
      sizes_attr,
      " decoding=\"",
      decoding,
      "\" />"
    ]
  end

  defp picture_iodata(%{webp_src: webp_src, webp_srcset: webp_srcset, img: img_opts})
       when is_binary(webp_src) do
    img = img_iodata(img_opts)

    source_srcset = webp_srcset || webp_src

    source_sizes_attr =
      optional_attr("sizes", sizes_for_srcset(webp_srcset, Map.get(img_opts, :sizes)))

    source_srcset_attr = optional_attr("srcset", source_srcset)

    [
      "<picture><source type=\"image/webp\"",
      source_srcset_attr,
      source_sizes_attr,
      ">",
      img,
      "</picture>"
    ]
  end

  defp sizes_for_srcset(nil, _sizes), do: nil
  defp sizes_for_srcset(_srcset, nil), do: nil
  defp sizes_for_srcset(_srcset, sizes), do: sizes

  defp optional_attr(_name, nil), do: ""
  defp optional_attr(name, val), do: " #{name}=\"#{escape_attr(val)}\""

  defp escape_attr(val) when is_binary(val) do
    val
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("'", "&#39;")
  end
end
