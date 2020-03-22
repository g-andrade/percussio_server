defmodule Percussio.DeviceConnectionListener do
  ## ------------------------------------------------------------------
  ## Macro-like Attribute Definitions
  ## ------------------------------------------------------------------

  @listener_ref __MODULE__

  ## ------------------------------------------------------------------
  ## Public Function Definitions
  ## ------------------------------------------------------------------

  def child_spec([]) do
    ref = @listener_ref
    transport = :ranch_tcp
    transport_opts = [port: 8000]
    protocol = Percussio.DeviceConnection
    protocol_opts = %{}
    :ranch.child_spec(
      ref, transport, transport_opts,
      protocol, protocol_opts)
  end
end
