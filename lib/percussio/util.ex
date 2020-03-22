defmodule Percussio.Util do
  ## ------------------------------------------------------------------
  ## API Definitions
  ## ------------------------------------------------------------------

  def validate_and_normalize_nonempty_strings([{tag, string} | next]) do
    case String.length(string) > 0 and Percussio.Util.maybe_normalize_string(string, :nfc) do
      {:ok, string} ->
        [{tag, string} | validate_and_normalize_nonempty_strings(next)]
      _ ->
        {:error, tag}
    end
  end

  def validate_and_normalize_nonempty_strings([]), do: []

  def maybe_normalize_string(string, norm)
  when is_binary(string) and norm in [:nfc, :nfd]
  do
    try do
      {:ok, String.normalize(string, norm)}
    rescue
      _ in FunctionClauseError ->
        :error
    end
  end

  def logger_safe_string(string) do
    quoted = "\"#{string}\""
    inspected = inspect(string)
    case String.equivalent?(quoted, inspected) do
      true -> string
      false -> inspected
    end
  end
end
