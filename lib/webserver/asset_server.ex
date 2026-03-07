defmodule Webserver.AssetServer do
  @moduledoc """
  Manages static asset paths and manifest resolution using ETS.
  """

  @behaviour Webserver.AssetResolver

  use GenServer
  require Logger

  @table_name :asset_manifest
  @meta_table_name :asset_meta
  @asset_extensions Webserver.Assets.asset_extensions()
  @static_prefix Webserver.Assets.static_prefix()
  @manifest_filename Webserver.Assets.manifest_filename()
  @meta_filename Webserver.Assets.meta_filename()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve(path) when is_binary(path) do
    case :ets.lookup(@table_name, path) do
      [{^path, resolved}] -> {:ok, resolved}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  @spec resolve_meta(String.t()) ::
          {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, :not_found}
  def resolve_meta(path) when is_binary(path) do
    case :ets.lookup(@meta_table_name, path) do
      [{^path, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:set, :public, :named_table])
    :ets.new(@meta_table_name, [:set, :public, :named_table])
    state = %{static_dir: Path.join(to_string(:code.priv_dir(:webserver)), "static")}
    {:ok, state, {:continue, :load_manifest}}
  end

  @impl true
  def handle_continue(:load_manifest, state) do
    manifest = load_manifest(state.static_dir)
    :ets.insert(@table_name, Map.to_list(manifest))

    meta = load_meta(state.static_dir)
    :ets.insert(@meta_table_name, Map.to_list(meta))

    {:noreply, state}
  end

  defp load_meta(static_dir) do
    meta_path = Path.join(static_dir, @meta_filename)

    case File.read(meta_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, meta} when is_map(meta) -> add_leading_slash_meta(meta)
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp add_leading_slash_meta(meta) do
    Map.new(meta, fn {k, v} ->
      width = Map.get(v, "width")
      height = Map.get(v, "height")
      {@static_prefix <> k, %{width: width, height: height}}
    end)
    |> Enum.reject(fn {_k, v} -> not is_integer(v.width) or not is_integer(v.height) end)
    |> Map.new()
  end

  defp load_manifest(static_dir) do
    manifest_path = Path.join(static_dir, @manifest_filename)

    Logger.debug(event: "load_manifest", static_dir: static_dir, exists: File.exists?(static_dir))

    case File.read(manifest_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            Logger.debug(event: "manifest_loaded", keys: Map.keys(manifest))
            add_leading_slash(manifest)

          {:error, _} ->
            Logger.debug(event: "manifest_parse_error")
            build_identity_manifest(static_dir)
        end

      {:error, reason} ->
        Logger.debug(event: "manifest_read_error", reason: reason)
        build_identity_manifest(static_dir)
    end
  end

  defp add_leading_slash(manifest) do
    Map.new(manifest, fn {k, v} -> {@static_prefix <> k, @static_prefix <> v} end)
  end

  defp build_identity_manifest(static_dir) do
    case Webserver.Assets.list_all_files(static_dir, relative: true) do
      {:ok, files} ->
        files
        |> Enum.filter(&asset_extension?(&1, @asset_extensions))
        |> then(&add_leading_slash(Map.new(&1, fn f -> {f, f} end)))

      {:error, _} ->
        %{}
    end
  end

  defp asset_extension?(path, extensions) do
    Enum.member?(extensions, Path.extname(path))
  end
end
