defmodule Webserver.AssetResolver do
  @moduledoc """
  Behaviour for resolving static asset paths and image metadata.
  """
  @callback resolve(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  @callback resolve_meta(String.t()) ::
              {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, :not_found}
end
