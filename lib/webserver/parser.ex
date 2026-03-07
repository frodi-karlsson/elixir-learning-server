defmodule Webserver.Parser do
  @moduledoc """
  Parses the custom HTML templating language, returning fully rendered HTML.
  """

  alias Webserver.Parser.{Img, ParseInput, Resolver, Tags}

  @type parse_error ::
          {:ref_not_found, String.t()}
          | {:missing_slots, [String.t()]}
          | {:missing_attrs, [String.t()]}
          | {:unexpected_slots, [String.t()]}
          | {:unresolved_asset, String.t()}
          | {:unresolved_image_meta, String.t()}
          | {:non_image_src, String.t()}
          | {:malformed_tag, String.t()}
          | {:unclosed_tag, String.t()}

  @type parse_result :: {:ok, String.t()} | {:error, parse_error()}

  @named_slot_regex ~r|<slot:([a-z_]+)>(.*?)</slot:\1>|s
  @slot_placeholder_regex ~r|\{\{([a-z_]+)\}\}|
  @attr_placeholder_regex ~r|\{\{@([a-zA-Z0-9_\-]+)\}\}|
  @asset_placeholder_regex ~r|\{\{\+\s*([^}]+?)\s*\}\}|

  @asset_tag_deprecation "asset tag is no longer supported; use {{+ /static/...}}"

  @spec parse(ParseInput.t()) :: parse_result()
  def parse(parse_input) do
    start_time = System.monotonic_time()
    metadata = %{template_dir: parse_input.template_dir}

    :telemetry.execute(
      [:webserver, :parser, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = render_tags(parse_input.file, parse_input)

    duration = System.monotonic_time() - start_time
    :telemetry.execute([:webserver, :parser, :stop], %{duration: duration}, metadata)

    result
  end

  defp render_tags(content, %ParseInput{} = parse_input) when is_binary(content) do
    with {:ok, rendered_iodata, rest} <- render_until(content, parse_input, nil, []) do
      if rest == "" do
        rendered = IO.iodata_to_binary(rendered_iodata)
        resolve_asset_placeholders(rendered, parse_input)
      else
        {:error, {:malformed_tag, "unexpected trailing content"}}
      end
    end
  end

  defp render_until(content, %ParseInput{} = parse_input, stop_name, acc)
       when is_binary(content) and is_list(acc) do
    case :binary.match(content, "<%") do
      :nomatch ->
        render_until_no_more_tags(content, stop_name, acc)

      {idx, 2} ->
        {prefix, rest} = split_at_open_tag(content, idx)

        with {:ok, tag, suffix_after_tag} <- Tags.next_tag(rest) do
          process_tag(tag, prefix, suffix_after_tag, parse_input, stop_name, acc)
        end
    end
  end

  defp render_until_no_more_tags(content, stop_name, acc) do
    if is_nil(stop_name) do
      {:ok, [acc, content], ""}
    else
      {:error, {:unclosed_tag, stop_name}}
    end
  end

  defp split_at_open_tag(content, idx) do
    prefix = binary_part(content, 0, idx)
    rest = binary_part(content, idx + 2, byte_size(content) - (idx + 2))
    {prefix, rest}
  end

  defp process_tag({:close, name}, prefix, suffix_after_tag, _parse_input, stop_name, acc) do
    if stop_name == name do
      {:ok, [acc, prefix], suffix_after_tag}
    else
      {:error, {:malformed_tag, "unexpected closing tag: #{name}"}}
    end
  end

  defp process_tag({:self, name, attrs}, prefix, suffix_after_tag, parse_input, stop_name, acc) do
    with {:ok, replacement} <- render_self_tag(name, attrs, parse_input) do
      render_until(suffix_after_tag, parse_input, stop_name, [acc, prefix, replacement])
    end
  end

  defp process_tag({:open, name, attrs}, prefix, suffix_after_tag, parse_input, stop_name, acc) do
    with {:ok, rendered_body, rest_after_close} <-
           render_until(suffix_after_tag, parse_input, name, []),
         {:ok, replacement} <-
           rendered_body
           |> IO.iodata_to_binary()
           |> then(&render_open_tag(name, attrs, &1, parse_input)) do
      render_until(rest_after_close, parse_input, stop_name, [acc, prefix, replacement])
    end
  end

  defp render_self_tag("asset", _attrs, _parse_input) do
    {:error, {:malformed_tag, @asset_tag_deprecation}}
  end

  defp render_self_tag("img", attrs, parse_input) do
    with {:ok, iodata} <- Img.render(attrs, parse_input) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  defp render_self_tag(name, attrs, parse_input) do
    render_partial(name, "", attrs, parse_input)
  end

  defp render_open_tag("asset", _attrs, _body, _parse_input) do
    {:error, {:malformed_tag, @asset_tag_deprecation}}
  end

  defp render_open_tag("img", _attrs, _body, _parse_input) do
    {:error, {:malformed_tag, "img tag must be self-closing"}}
  end

  defp render_open_tag(name, attrs, body, parse_input) do
    render_partial(name, body, attrs, parse_input)
  end

  defp render_partial(name, raw_content, attrs, parse_input) do
    partial_name = String.trim(name)

    case Resolver.resolve_partial_reference(partial_name, parse_input) do
      partial when is_binary(partial) ->
        render_partial_with_slots_and_attrs(partial, raw_content, attrs, parse_input)

      nil ->
        {:error, {:ref_not_found, partial_name}}
    end
  end

  defp render_partial_with_slots_and_attrs(partial, raw_content, attrs, parse_input) do
    case extract_named_slots(raw_content, parse_input) do
      {:ok, _content, slot_map} ->
        expected_slots = extract_expected_slots(partial)
        slot_map = merge_metadata_slots(slot_map, expected_slots, parse_input.metadata)
        expected_attrs = extract_expected_attrs(partial)

        with :ok <- validate_slots(expected_slots, slot_map),
             :ok <- validate_attrs(expected_attrs, attrs) do
          rendered =
            partial
            |> replace_slots(slot_map, expected_slots)
            |> replace_attrs(attrs, expected_attrs)

          render_tags(rendered, parse_input)
        end

      error ->
        error
    end
  end

  defp merge_metadata_slots(slot_map, expected, metadata) do
    Enum.reduce(expected, slot_map, &do_merge_metadata_slot(&1, &2, metadata))
  end

  defp do_merge_metadata_slot(name, acc, metadata) do
    if Map.has_key?(acc, name) do
      acc
    else
      metadata |> Map.get(name) |> maybe_put_slot(acc, name)
    end
  end

  defp maybe_put_slot(nil, acc, _name), do: acc
  defp maybe_put_slot(val, acc, name), do: Map.put(acc, name, to_string(val))

  defp resolve_asset_placeholders(content, parse_input) do
    matches = Regex.scan(@asset_placeholder_regex, content, return: :index)

    if matches == [] do
      {:ok, content}
    else
      with {:ok, rendered_iodata} <-
             resolve_asset_placeholder_matches(content, matches, parse_input) do
        {:ok, IO.iodata_to_binary(rendered_iodata)}
      end
    end
  end

  defp resolve_asset_placeholder_matches(content, matches, parse_input)
       when is_binary(content) and is_list(matches) do
    result =
      Enum.reduce_while(matches, {0, []}, fn
        [{full_start, full_len}, {path_start, path_len}], {cursor, acc} ->
          prefix = binary_part(content, cursor, full_start - cursor)

          path =
            content
            |> binary_part(path_start, path_len)
            |> String.trim()
            |> strip_wrapping_quotes()

          case resolve_asset(path, parse_input) do
            {:ok, resolved} ->
              {:cont, {full_start + full_len, [acc, prefix, resolved]}}

            {:error, _} = error ->
              {:halt, error}
          end
      end)

    case result do
      {:error, _} = error ->
        error

      {cursor, iodata} when is_integer(cursor) ->
        suffix = binary_part(content, cursor, byte_size(content) - cursor)
        {:ok, [iodata, suffix]}
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

  defp strip_wrapping_quotes(<<q::binary-size(1), rest::binary>>) when q in ["\"", "'"] do
    if String.ends_with?(rest, q) and byte_size(rest) >= 1 do
      String.trim_trailing(rest, q)
    else
      q <> rest
    end
  end

  defp strip_wrapping_quotes(other), do: other

  defp extract_named_slots(content, parse_input) do
    case Regex.run(@named_slot_regex, content, return: :index) do
      nil ->
        {:ok, content, %{}}

      [{slot_start, slot_len}, {name_start, name_len}, {content_start, content_len}] ->
        slot_name = binary_part(content, name_start, name_len)
        slot_content = binary_part(content, content_start, content_len)
        full_match = binary_part(content, slot_start, slot_len)
        new_content = String.replace(content, full_match, "{{#{slot_name}}}", global: false)

        with {:ok, processed} <- render_tags(slot_content, parse_input),
             {:ok, remaining, more_slots} <- extract_named_slots(new_content, parse_input) do
          {:ok, remaining, Map.put(more_slots, slot_name, processed)}
        end
    end
  end

  defp extract_expected_slots(partial) do
    @slot_placeholder_regex
    |> Regex.scan(partial)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp extract_expected_attrs(partial) do
    @attr_placeholder_regex
    |> Regex.scan(partial)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp validate_slots(expected, slot_map) do
    provided = slot_map |> Map.keys() |> MapSet.new()
    expected_set = MapSet.new(expected)

    missing = expected_set |> MapSet.difference(provided) |> MapSet.to_list()
    unexpected = provided |> MapSet.difference(expected_set) |> MapSet.to_list()

    cond do
      expected_set == provided -> :ok
      missing != [] -> {:error, {:missing_slots, missing}}
      true -> {:error, {:unexpected_slots, unexpected}}
    end
  end

  defp validate_attrs(expected, attrs) do
    provided = attrs |> Map.keys() |> MapSet.new()
    expected_set = MapSet.new(expected)
    missing = expected_set |> MapSet.difference(provided) |> MapSet.to_list()

    if missing == [] do
      :ok
    else
      {:error, {:missing_attrs, missing}}
    end
  end

  defp replace_slots(partial, slot_map, expected_slots) do
    if expected_slots == [] do
      partial
    else
      Regex.replace(@slot_placeholder_regex, partial, fn _match, slot_name ->
        Map.fetch!(slot_map, slot_name)
      end)
    end
  end

  defp replace_attrs(partial, attrs, expected_attrs) do
    if expected_attrs == [] do
      partial
    else
      Regex.replace(@attr_placeholder_regex, partial, fn _match, attr_name ->
        Map.fetch!(attrs, attr_name)
      end)
    end
  end
end
