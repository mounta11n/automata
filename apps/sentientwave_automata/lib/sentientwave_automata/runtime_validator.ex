defmodule SentientwaveAutomata.RuntimeValidator do
  @moduledoc false

  use GenServer

  alias SentientwaveAutomata.RuntimeConfig

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    RuntimeConfig.validate!()
    {:ok, state}
  end
end
