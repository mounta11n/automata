defmodule SentientwaveAutomataTemporal.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if bootstrap_enabled?() do
        [SentientwaveAutomataTemporal.Bootstrap]
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SentientwaveAutomataTemporal.Supervisor
    )
  end

  defp bootstrap_enabled? do
    Application.get_env(:sentientwave_automata_temporal, :bootstrap_enabled, true)
  end
end
