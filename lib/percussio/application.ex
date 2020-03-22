defmodule Percussio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: Percussio.Worker.start_link(arg)
      # {Percussio.Worker, arg},
      Percussio.March,
      Percussio.DeviceConnectionListener
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Percussio.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
