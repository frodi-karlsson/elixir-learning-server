defmodule Webserver.AssetResolver.Sandbox do
  @moduledoc """
  In-memory asset resolver for tests. Provides fixed test data covering all parser test scenarios.
  """

  @behaviour Webserver.AssetResolver

  @manifest %{
    "/static/img/web-vitals.png" => "/static/img/web-vitals.testhash.png",
    "/static/img/web-vitals.w728.png" => "/static/img/web-vitals.w728.testhash.png",
    "/static/img/web-vitals.webp" => "/static/img/web-vitals.testhash.webp",
    "/static/img/web-vitals.w728.webp" => "/static/img/web-vitals.w728.testhash.webp",
    "/static/img/no-meta.png" => "/static/img/no-meta.testhash.png",
    "/static/css/app.css" => "/static/css/app.testhash.css"
  }

  @meta %{
    "/static/img/web-vitals.png" => %{width: 876, height: 378},
    "/static/img/web-vitals.webp" => %{width: 876, height: 378}
  }

  @impl true
  def resolve(path) when is_binary(path) do
    case Map.fetch(@manifest, path) do
      {:ok, resolved} -> {:ok, resolved}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def resolve_meta(path) when is_binary(path) do
    case Map.fetch(@meta, path) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, :not_found}
    end
  end
end
